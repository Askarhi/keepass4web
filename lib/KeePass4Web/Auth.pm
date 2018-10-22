package KeePass4Web::Auth;
use strict;
use warnings;

use Dancer2 appname => 'KeePass4Web';

# Simple wrapper for backends


return 1 if !config->{auth_backend};

my $type = __PACKAGE__ . '::' . config->{auth_backend};
(my $module = $type) =~ s/::/\//g;
require $module . '.pm';

my $auth = $type->new;

if (!$auth->DOES(__PACKAGE__ . '::Abstract')) {
    die "$type does not inherit from " . __PACKAGE__ . '::Abstract';
}

# auth attempt with configured backend
# MUST die on error
# MAY return HoA with more info on the authenticated user
sub auth { defined($auth) and $auth->auth(@_) }

sub case_sensitive { defined($auth) and $auth->case_sensitive(@_) }

1;
