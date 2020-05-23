unit module Commands;

use Matrix;

our grammar Shared {
  token Name { $name ':'? }
  token Quotes { "\"" | "'" | "`" }
  token QuotedValue { <Quotes> [ <.alnum> | \s]+ <Quotes> }
  token NumericValue { <.digit>+ | 0x <.xdigit>+}
  token Value { <NumericValue> | <QuotedValue> }
  token Politeness { :i "please" | "pls" | "plz" | "ty" | "thx" | "cheers" }
}

our grammar Command is Shared {
  token TOP { <Name> \s+ <Word> [\s+ <Value>]? [ \,? \s+ <Politeness>]? }
  token Word { \w+ }
}

our grammar SetVar is Shared {
  token TOP { <Name> \s+ <Change> \s+ <Var> \s+ <To> \s+ <Value> [ \,? \s+ <Politeness>]? }
  token Var { <Value> }
  token Change { :i "set" | "change" }
  token To { :i "to" | "to be" | "=" }
}


my %changers = {
  name => change-name;
}


Matrix::<$msg-supply>.tap( -> %event {
  my %session = %event<session>;
  my $room = %event<room>;
  my %msg = %event<msg>;
  my $sender = %msg<sender>;
  my $text = %msg<content><body>;

  if SetVar.parse($text) {
    my $var = $_<Var>;
    my $val = $_<Value>;
    my $politeness = $_<Politeness>;

    if not $politeness {
      send-txt-msg($room, "$sender: rude.");
    } elsif %changers{$var} {
      %changers{$var}($val);
      send-txt-msg($room, "$sender: CHeangign $var to $val");
    } else {
      send-txt-msg($room, "$sender: That ain't a thing");
    }
  } elsif Command.parse($text) {

  } elsif %msg<content><body>.starts-with(%session<display-name>) {

    send-txt-msg($room, "$sender: I haer yuo bro");
  }
});