package SlimSignature;

use Moose;
use Text::Balanced qw(
  extract_codeblock 
  extract_variable
  extract_quotelike
);
use Carp qw/croak/;

has 'tokens' => (
  is => 'ro',
  isa => 'ArrayRef',
  init_arg => undef,
  default => sub { [] },
);

has 'input' => (
  is => 'ro',
  isa => 'Str',
  required => 1
);

has '_input' => (
  is => 'ro',
  isa => 'ScalarRef',
  init_arg => undef,
  lazy_build => 1
);

sub _build__input {
    my $var = $_[0]->input;
    return \$var;
}

# signature: O_PAREN
#            invocant
#            params
#            C_PAREN
#
# params: param COMMA params
#       | param
#       | /* NUL */
sub signature {
  my ($self, $data) = @_;

  $self = $self->new(input => $data);

  $self->assert_token('(');

  my $sig = {};
  my $params = [];

  my $param = $self->param;

  if ($param && $self->token->{type} eq ':') {
    # That param was actualy the invocant
    $sig->{invocant} = $param;
    $self->consume_token;
    $param = $self->param;
  }

  push @$params, $param
    if $param;

  # Params can be sperarated by , or \n
  while ($self->token->{type} eq ',' ||
         $self->token->{type} eq "\n") {
    $self->consume_token;

    $param = $self->param;
    die "parameter expected"
      if !$param;
    push @$params, $param;
  }

  $self->assert_token(')');
 
  return $sig;
}

# param: classishTCName?
#        COLON?
#        var
#        (OPTIONAL|REQUIRED)
#        default?
#        where*
sub param {
  my ($self, $data) = @_;
  $self = $self->new(input => $data)
    unless blessed($self);

  my $param = {};
  my $consumed = 0;

  my $token = $self->token;
  if ($token->{type} eq 'class') {
    $param->{tc} = $token->{literal};
    $self->consume_token;
    $token = $self->token;
    while ($token->{type} eq '|') {
      $self->consume_token;
      $token = $self->token;
      $param->{tc} .= '|' . $self->assert_token('class')->{literal};
      $token = $self->token;
    }
    $consumed = 1;
  }

  if ($token->{type} eq ':') {
    $param->{named} = 1;
    $self->consume_token;
    $token = $self->token;
    $consumed = 1;
  }

  return if (!$consumed && $token->{type} ne 'var');

  $param->{var} = $self->assert_token('var');
  $token = $self->token;

  if ($token->{type} eq '?') {
    $param->{optional} = 0;
    $self->consume_token;
    $token = $self->token;
  } elsif ($token->{type} eq '!') {
    $param->{required} = 1;
    $self->consume_token;
    $token = $self->token;
  }

  if ($token->{type} eq '=') {
    # default value
    $self->consume_token;

    $param->{default} = $self->value_ish();

    $token = $self->token;
  }

  while ($token->{type} eq 'WHERE') {
    $self->consume_token;

    $param->{where} ||= [];
    my ($code) = extract_codeblock(${$self->_input});

    # Text::Balanced *sets* $@. How horrible.
    die "$@" if $@; 

    substr(${$self->_input}, 0, length($code), '');
    push @{$param->{where}}, $code;

    $token = $self->token;
  }

  #use Data::Dumper; $Data::Dumper::Indent = 1;warn Dumper($param);
  return $param;
}

# Used by default production.
#
# value_ish: number_literal
#          | quote_like
#          | variable
#          | balanced
#          | closure

sub value_ish {
  my ($self) = @_;

  my $data = $self->_input;
  my $num = $self->_number_like;
  return $num if defined $num;

  my $default = $self->_quote_like || $self->_variable_like;
  return $default;
}

sub _number_like {
  my ($self) = @_;
  # This taken from Perl6::Signatures, which in turn took it from perlfaq4
  my $number_like = qr/^
                      ( ([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?# float
                      | -?(?:\d+(?:\.\d*)?|\.\d+)                      # decimal
                      | -?\d+\.?\d*                                    # real
                      | [+-]?\d+                                       # +ve or -ve integer
                      | -?\d+                                          # integer
                      | \d+                                            # whole number
                      | 0x[0-9a-fA-F]+                                 # hexadecimal
                      | 0b[01]+                                        # binary
                      # note that octals will be captured by the "whole number"
                      # production. Our consumer will have to eval this (we don't
                      # want to do it for them because of roundtripping. But maybe
                      # we need annotation nodes anyway?
                      )/x;
  
  my $data = $self->_input;

  my ($num) = $$data =~ /$number_like/;

  if (defined $num) {
    substr($$data, 0, length($num), '');
    return $num;
  }
  return undef;
}

sub _quote_like {
  my ($self) = @_;

  my $data = $self->_input;

  my @quote = extract_quotelike($$data);

  die "$@" if $@; 
  return unless $quote[0];

  my $op = $quote[4];

  my %whitelist = map { $_ => 1 } qw(q qq qw qr " ');
  die "rejected quotelike operator: $op" unless $whitelist{$op};

  substr($$data, 0, length $quote[0], '');

  return $quote[0];
}

sub _variable_like {
  my ($self) = @_;

  my $data = $self->_input;
  my @var = extract_quotelike($$data);

  die "$@" if $@; 
}

sub assert_token {
  my ($self, $type) = @_;

  if ($self->token->{type} eq $type) {
    return $self->consume_token;
  }
 
  Carp::confess "$type required, found  '" .$self->token->{literal} . "'!";
}

sub token {
  my ($self, $la) = @_;

  $la ||= 0;

  while (@{$self->tokens} <= $la) {
    my $token = $self->next_token($self->_input);

    die "Unexepcted EoF"
      unless $token;

    push @{$self->tokens}, $token;
  }
  return $self->tokens->[$la];
}

sub consume_token {
  my ($self) = @_;

  die "No token to consume"
    unless @{$self->tokens};
    
  return shift @{$self->tokens};
}

our %LEXTABLE = (
  where => 'WHERE'
);

sub next_token {
  my ($self, $data) = @_;

  if ($$data =~ s/^(\s*[\r\n]\s*)//xs) {
    return { type => "\n", literal => $1 }
  }

  my $re = qr/^ \s* (?:
    ([(){},:=|!?\n]) |
    (
      [A-Za-z][a-zA-Z0-0_-]+
      (?:::[A-Za-z][a-zA-Z0-0_-]+)*
    ) |
    (\$[_A-Za-z][a-zA-Z0-9_]*)
  ) \s* /x;

  # symbols in $1
  # class-name ish in $2
  # $var in $3

  unless ( $$data =~ s/$re//) {
    die "Error parsing signature at '" . substr($$data, 0, 10);
  }

  my ($sym, $cls,$var) = ($1,$2,$3);

  return { type => $sym, literal => $sym }
    if defined $sym;

  if (defined $cls) {
    if ($LEXTABLE{$cls}) {
      return { type => $LEXTABLE{$cls}, literal => $cls };
    }
    return { type => 'class', literal => $cls };
  }

  return { type => 'var', literal => $var }
    if $var;


  die "Shouldn't get here!";
}

1;

