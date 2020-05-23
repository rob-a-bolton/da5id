unit module Matrix;
use Config;
use WWW :extras;
use JSON::Fast :ALL;
use Log::Async;


our %session;

class Login is export {
  has Str $.session;
  has Str $.username;
  has Str $.password;
}

class LoginResponse is export {
  has Str $.access-token;
  has Str $.device-id;
  has Str $.home-server;
  has Str $.user-id;
}

class RoomStatus is export {
  has @.timeline-events;
}

class RoomInvite is export {
  has Str $.room-id;
  has $.room-name;
  has Str $.invitee;
  has Str $.membership-type;

  method from-invite(::?CLASS:U $inv-class: $invite) {
    my $room-id = $invite.key;
    my $room-name;
    my $invitee;
    my $membership-type;

    for @($invite.value<invite_state><events>) -> %event {
      if %event<type> ~~ "m.room.name" {
        $room-name = %event<content><name>;
      } elsif %event<type> ~~ "m.room.member" {
        $invitee = %event<sender>;
        $membership-type = %event<content><membership>
      }
    }

    $inv-class.bless(:$room-id, :$room-name, :$invitee, :$membership-type)
  }
}

class SyncResponse is export {
  has RoomStatus %.room-statuses;
  has RoomInvite @.room-invites;
  has Str $.next-batch;

  method from-json(::?CLASS:U $res-class: %json) {
    my %room-statuses-json = %json<rooms><join>;
    my %room-invites-json = %json<rooms><invite>;

    my $next-batch = %json<next_batch>;

    my %room-statuses = %(%room-statuses-json.kv.map( -> $room-id, $room {
      $room-id => RoomStatus.new(
        timeline-events => @($room.<timeline><events>)
      )
    }));

    my @room-invites = %room-invites-json.map( -> $invite {
      RoomInvite.from-invite($invite)
    });

    $res-class.bless(:%room-statuses, :$next-batch, :@room-invites);
  }
}

my $running-promise = Promise.new;

my $server-supplier = Supplier.new;
our $server-supply = $server-supplier.Supply;

my $session-supplier = Supplier.new;
our $session-supply = $session-supplier.Supply;

my $msg-supplier = Supplier.new;
our $msg-supply = $msg-supplier.Supply;

my $room-event-supplier = Supplier.new;
our $room-event-supply = $room-event-supplier.Supply;

my $id-cnt = 0;


sub get-api-versions($domain) is export {
    my $response = jget($domain.fmt('https://%s/_matrix/client/versions'));
    say($response);
}

sub login(%server) is export {
    info "Logging into server %server";
    my $domain = %server<address>;
    my %login-data := {
        type => "m.login.password",
        user => %server<username>,
        password => %server<password>
    };
    say(%server);
    if %server<deviceid>:exists {
        %login-data<device_id> = %server<deviceid>;
    }
    my %response = jpost("https://$domain/_matrix/client/r0/login",
                         to-json(%login-data));

    %server<token> = %response<access_token>;

    if not %server<deviceid>:exists {
        %server<deviceid> = %response<device_id>;
        update-config();
    }

    my $token = %server<token>;
    my %room-response = jget("https://$domain/_matrix/client/r0/joined_rooms?access_token=$token");
    my @joined = %room-response<joined_rooms>;
    %server<rooms> = @joined;
    my %profile-response = jget("https://$domain/_matrix/client/r0/profile/\@%server<username>:$domain?access_token=$token");
    %server<display-name> = %profile-response<displayname>;

    %session = %server;

    return %server;
}

sub sync() is export {
    my $domain = %session<address>;
    if %session<deviceid>:exists {
        %session<device_id> = %session<deviceid>;
    }

    my $response;
    if %session<since>:exists {
      $response = SyncResponse.from-json(jget("https://$domain/_matrix/client/r0/sync?access_token=%session<token>&since=%session<since>"));
    } else {
      $response = SyncResponse.from-json(jget("https://$domain/_matrix/client/r0/sync?access_token=%session<token>"));
    }
    say $response;

    my $token = %session<access_token>;
    if $response.next-batch {
      %session<since> = $response.next-batch;
    }

    for $response.room-statuses.kv -> $room-id, $room-data {
      my @events := $room-data.timeline-events;

      for @events -> %event {
        info "room-dat[$room-id]: {%event<event_id>}, type: {%event.^name}";
        $room-event-supplier.emit({
          session => %session,
          room => $room-id,
          event => %event,
        });
      }
    }

    if $response.room-invites {
      for $response.room-invites -> $invite {
        join-room($invite.room-id);
        send-txt-msg($invite.room-id, "Thx {$invite.invitee}");
      }
    }
}

our sub change-name($name) {
  my $user-id = %session<username>;
  my $domain = %session<address>;
  my $token = %session<token>;
  my $res = jput("https://$domain/_matrix/client/r0/profile/$user-id/displayname?access_token=$token",
                 to-json({displayName => $name}));
  %session<display-name> = $name;
}

our sub join-room($room) {
  my $domain = %session<address>;
  my $token = %session<token>;
  my %response := jpost("https://$domain/_matrix/client/r0/rooms/$room/join?access_token=$token",
                  to-json({}));
}

our sub send-msg($room, %msg) {
    my $domain = %session<address>;
    my $token = %session<token>;
    my $mid = $id-cnt++;

    my $url = "https://$domain/_matrix/client/r0/rooms/$room/send/m.room.message/$mid?access_token=$token";
    info "Sending message {%msg}";
    my %response := jput($url, to-json(%msg));
}

our sub send-txt-msg($room, $text) is export {
  my %msg := {
        msgtype => "m.text",
        body => $text,
  };
  send-msg($room, %msg)
}

sub init-matrix() is export {
  login(%config<server>);

  %session<sync-schedule> = Supply.interval(1).tap({
    sync();
  });

  $room-event-supply.tap( -> %vars {
    my $room = %vars<room>;
    my %event = %vars<event>;
    if %event<type> ~~ "m.room.message" {
      $msg-supplier.emit({
        room => $room,
        msg => %event
      });
    }
  });

  return $running-promise;
}
