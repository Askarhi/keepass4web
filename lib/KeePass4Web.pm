package KeePass4Web;
use strict;
use warnings;

use Dancer2;
use Dancer2::Plugin::Ajax;
use Dancer2::Core::Time;
use MIME::Base64 qw/encode_base64 decode_base64/;
use Crypt::URandom;

BEGIN {
    # change to correct dir if using mod_perl2
    if ($ENV{MOD_PERL} || $ENV{MOD_PERL_API_VERSION}) {
        chdir config->{appdir};
    }
}

use KeePass4Web::KeePass;
use KeePass4Web::Backend;
use KeePass4Web::Auth;
use KeePass4Web::Constant;

use constant DB_TIMEOUT    => Dancer2::Core::Time->new(expression => config->{db_session_timeout})->seconds;
use constant AUTH_INTERVAL => Dancer2::Core::Time->new(expression => config->{auth_check_interval})->seconds;

BEGIN {
    # export doesn't work with Dancer2
    *KeePass4Web::failure = \&KeePass4Web::KeePass::failure;
    *KeePass4Web::success = \&KeePass4Web::KeePass::success;
}


hook before => sub {
    # TODO: check here for 'authenticated', to allow empty user authentication (auth_backend = '')

    my $session = session SESSION_USERNAME;
    # check session
    if (!$session and request->path !~ m{^(?:/|/user_login|/authenticated)$}) {
        halt failure 'Not logged in', UNAUTHORIZED;
    }
    # check CSRF token, with some exceptions
    elsif ($session and request->path !~ m{^(?:/|/csrf_token)$|^/img/icon/}) {
        my $token = session(SESSION_CSRF) || '';
        my $csrf_param = KeePass4Web::Backend::credentials_tpl;
        my $param_token = request_header('X-CSRF-Token') || param($csrf_param && $csrf_param->{csrf_param} || '') || '' ;
        if ($token ne $param_token) {
            send_error 'CSRF token validation failed', FORBIDDEN;
        }
    }
};

ajax '/user_login' => sub {
    return failure 'No user authentication configured', MTHD_NOT_ALLOWED if !config->{auth_backend};
    return failure 'Already logged in', MTHD_NOT_ALLOWED if session SESSION_USERNAME;

    my $username = param 'username';
    my $password = param 'password';

    if (!defined $username or !defined $password) {
        return failure 'Username or password not supplied', UNAUTHORIZED;
    }

    info 'User login attempt: ', $username;

    # may return more info of user as HoA
    my $userinfo = eval {
        KeePass4Web::Auth::auth($username, $password);
    };
    if ($@) {
        debug "$username: $@";
        # passing standard error message, won't give any clues to attackers
        return failure 'User authentication failed', UNAUTHORIZED;
    }

    my $case_sensitive = KeePass4Web::Auth::case_sensitive;
    # default: case sensitive
    if (defined $case_sensitive && $case_sensitive ne 0) {
        # something else than 1: look into userinfo
        my $attr = $case_sensitive;
        if ($case_sensitive ne 1 && ref $userinfo eq 'HASH' && $userinfo->{$attr}) {
            $username = $userinfo->{$attr}->[0];
        }
        # case_sensitive is 1 or can't find proper userinfo: case insensitive
        else{
            $username = lc $username
        }
    }

    debug 'User info: ', $userinfo;

    if (config->{auth_reuse_cred}) {
        eval {
            KeePass4Web::Backend::credentials_init(scalar params);
        };
        if ($@) {
            debug "$username: $@";
            # warn only and give user chance to enter deviating credentials
            warning "User $username: Backend credentials reuse configured, but backend authentication failed";
        }
    }

    info 'User login successful: ', $username;
    session SESSION_USERNAME, $username;

    my $csrf_token = encode_base64 Crypt::URandom::urandom(CSRF_TOKEN_LENGTH), '';
    session SESSION_CSRF, $csrf_token;

    # set a CN to display on the web interface
    my $cn = ref $userinfo eq 'HASH' && $userinfo->{CN} ? $userinfo->{CN}->[0] : undef;
    $cn //= $username;
    session SESSION_CN, $cn;

    return success 'Login successful', {
        csrf_token => $csrf_token,
        settings => {
            cn       => $cn,
            template => KeePass4Web::Backend::credentials_tpl(),
            timeout  => DB_TIMEOUT,
            interval => AUTH_INTERVAL,
        }
    }
};


ajax '/backend_login' => sub {
    return failure 'Already logged into backend', MTHD_NOT_ALLOWED if eval { KeePass4Web::Backend::authenticated };

    my $params = params;

    unless (ref $params eq 'HASH' && %$params) {
        return failure 'No parameters supplied', UNAUTHORIZED;
    }


    # param check happens downstream
    eval {
        KeePass4Web::Backend::credentials_init($params)
    };
    if ($@) {
        debug session(SESSION_USERNAME), ": $@";
        # using error message of backend, in case something like decryption of a repository fails
        # and we need to distinguish (and give a hint to the user)
        return failure $@, UNAUTHORIZED;
    }


    return success 'Login successful';
};


ajax '/db_login' => sub {
    return failure 'DB already open', MTHD_NOT_ALLOWED if eval { KeePass4Web::KeePass::open };

    my $password = param 'password';
    # grabbing the hidden base64 encoded input field
    my $keyfile  = param 'key';


    if (!$password and !$keyfile) {
        return failure 'Neither password nor keyfile supplied';
    }

    info session(SESSION_USERNAME), ': DB decryption attempt';

    if ($keyfile) {
        # cut html file api prefix and decode from base64
        my $key = param 'key';
        $key =~ s/^.*?,//;
        $keyfile = eval { decode_base64 $key };
        if ($@) {
            info session(SESSION_USERNAME), ": $@";
            return failure 'Failed to parse key file';
        }
    }

    eval {
        KeePass4Web::KeePass::fetch_and_decrypt(password => $password, keyfile => \$keyfile);
    };
    if ($@) {
        info session(SESSION_USERNAME), ": $@";
        return failure 'DB decryption failed', UNAUTHORIZED;
    }

    info session(SESSION_USERNAME), ': DB decryption successful';

    return success 'Login successful';
};


ajax '/logout' => sub {
    eval { KeePass4Web::KeePass::clear_db };
    my $username = session SESSION_USERNAME;
    app->destroy_session;
    return failure 'Not logged in', MTHD_NOT_ALLOWED if !$username;
    return success 'Logged out';
};

ajax '/authenticated' => sub {
    my %auth = (
        user    => 0+!config->{auth_backend},
        backend => 0,
        db      => 0,
    );

    # shortcut, if auth backend is configured and user auth is false
    # setting $auth{user} to reuse it further below
    if (config->{auth_backend} and not $auth{user} = 0+!!session SESSION_USERNAME) {
        return failure \%auth, UNAUTHORIZED;
    }

    $auth{backend} = 1 if eval { KeePass4Web::Backend::authenticated };
    $auth{db}      = 1 if eval { KeePass4Web::KeePass::open };

    # return auth fail if any auth is false
    foreach my $val (values %auth) {
        return failure \%auth, UNAUTHORIZED if !$val;
    }

    return success 'Authenticated';
};

ajax '/settings' => sub {
    return success undef, {
        cn       => session(SESSION_CN),
        template => KeePass4Web::Backend::credentials_tpl(),
        timeout  => DB_TIMEOUT,
        interval => AUTH_INTERVAL,
    };
};

ajax '/csrf_token' => sub {
    return success undef, {
        csrf_token => session(SESSION_CSRF),
    };
};

any ['post', 'get'] => '/' => sub {
    send_file 'index.html';
};


1;
