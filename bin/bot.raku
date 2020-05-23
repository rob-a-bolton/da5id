#!/usr/bin/env raku

use lib 'lib';
use Matrix;
use Config;
use Commands;

use Log::Async;
logger.send-to("./da5id.log");


sub MAIN() {
  get-config();
  Matrix::<$room-event-supply>.tap( -> %event {
    info "%event";
  });
  # Matrix::<$session-supply>.tap( -> %session {
  #   for %session<rooms> -> $room {
  #       send-txt-msg(%session, $room, "Sup cunts");
  #   }
  # });
  Matrix::<$msg-supply>.tap( -> %event {
    say %event;
    my $room = %event<room>;
    my %msg = %event<msg>;
    my $sender = %msg<sender>;
    say "SESSION IS ", %Matrix::session;
    if %msg<content><body>.starts-with(%Matrix::session<cmd-str>) {
      info "Sending message $room | $sender";
      send-txt-msg($room, "$sender: Get fucked");
    } elsif %msg<content><body>.starts-with(%Matrix::session<display-name>) {
      info "Someone pinged us";
      send-txt-msg($room, "$sender: I haer yuo bro");
    }
  });

  my $running = init-matrix();
  await $running;

  info "Bot initialised";
}
