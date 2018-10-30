use strict;
use warnings;
use JSON;
use DBI;
use Plack::Builder;
use Plack::Request;

# Need to make this configurable in an external file
my $dsn = 'DBI:MariaDB:database=lightapi;host=localhost';
my $db_user = 'lightapiro';
my $db_password = 'lightapiro';

my $dbh;
my $sth_getnet;
my $sth_res;
my $sth_bal;
my $sth_perms;
my $sth_keys;
my $sth_authacc;

sub check_dbserver
{
    if ( not defined($dbh) or not $dbh->ping() ) {
        $dbh = DBI->connect($dsn, $db_user, $db_password,
                            {'RaiseError' => 1, AutoCommit => 0,
                             'mariadb_server_prepare' => 1});
        die($DBI::errstr) unless $dbh;

        $sth_getnet = $dbh->prepare
            ('SELECT network, chainid, description, systoken, decimals ' .
             'FROM LIGHTAPI_NETWORKS WHERE network=?');

        $sth_res = $dbh->prepare
            ('SELECT block_num, block_time, trx_id, ' .
             'cpu_weight AS cpu_stake, net_weight AS net_stake, ' .
             'ram_quota AS ram_total_bytes, ram_usage AS ram_usage_bytes ' .
             'FROM LIGHTAPI_LATEST_RESOURCE ' .
             'WHERE network=? AND account_name=?');

        $sth_bal = $dbh->prepare
            ('SELECT block_num, block_time, trx_id, contract, currency, amount ' .
             'FROM LIGHTAPI_LATEST_CURRENCY ' .
             'WHERE network=? AND account_name=?');

        $sth_perms = $dbh->prepare
            ('SELECT perm, threshold, block_num, block_time, trx_id ' .
             'FROM LIGHTAPI_AUTH_THRESHOLDS ' .
             'WHERE network=? AND account_name=?');

        $sth_keys = $dbh->prepare
            ('SELECT pubkey, weight ' .
             'FROM LIGHTAPI_AUTH_KEYS ' .
             'WHERE network=? AND account_name=? AND perm=?');

        $sth_authacc = $dbh->prepare
            ('SELECT actor, permission, weight ' .
             'FROM LIGHTAPI_AUTH_ACC ' .
             'WHERE network=? AND account_name=? AND perm=?');
    }
}


sub get_network
{
    my $name = shift;
    $sth_getnet->execute($name);
    my $r = $sth_getnet->fetchall_arrayref({});
    return $r->[0];
}

my $json = JSON->new();
my $jsonp = JSON->new()->pretty->canonical;

my $builder = Plack::Builder->new;

$builder->mount
    ('/api/networks' => sub {
         my $env = shift;
         my $req = Plack::Request->new($env);

         check_dbserver();
         my $result = $dbh->selectall_arrayref
             ('SELECT network, chainid, description, systoken, decimals ' .
              'FROM LIGHTAPI_NETWORKS', {Slice => {}});
         $dbh->commit();

         my $res = $req->new_response(200);
         $res->content_type('application/json');
         my $j = $req->query_parameters->{pretty} ? $jsonp:$json;
         $res->body($j->encode($result));
         $res->finalize;
     });

$builder->mount
    ('/api/account' => sub {
         my $env = shift;
         my $req = Plack::Request->new($env);
         my $path_info = $req->path_info;

         if ( $path_info !~ /^\/(\w+)\/([a-z1-5.]{1,13})$/ ) {
             my $res = $req->new_response(400);
             $res->content_type('text/plain');
             $res->body('Expected a network name and a valid EOS account name in URL path');
             return $res->finalize;
         }

         my $network = $1;
         my $acc = $2;
         check_dbserver();

         my $netinfo = get_network($network);
         if ( not defined($netinfo) ) {
             my $res = $req->new_response(400);
             $res->content_type('text/plain');
             $res->body('Unknown network name: ' . $network);
             return $res->finalize;
         }

         my $j = $req->query_parameters->{pretty} ? $jsonp:$json;

         my $result = {'account_name' => $acc, 'chain' => $netinfo};

         $sth_res->execute($network, $acc);
         $result->{'resources'} = $sth_res->fetchrow_hashref();

         $sth_bal->execute($network, $acc);
         $result->{'balances'} = $sth_bal->fetchall_arrayref({});

         $sth_perms->execute($network, $acc);
         my $perms = $sth_perms->fetchall_arrayref({});
         foreach my $permission (@{$perms}) {
             $sth_keys->execute($network, $acc, $permission->{'perm'});
             $permission->{'auth'}{'keys'} = $sth_keys->fetchall_arrayref({});

             $sth_authacc->execute($network, $acc, $permission->{'perm'});
             $permission->{'auth'}{'accounts'} = $sth_authacc->fetchall_arrayref({});
         }

         $result->{'permissions'} = $perms;

         $dbh->commit();

         my $res = $req->new_response(200);
         $res->content_type('application/json');

         $res->body($j->encode($result));
         $res->finalize;
     });


$builder->to_app;



# Local Variables:
# mode: cperl
# indent-tabs-mode: nil
# cperl-indent-level: 4
# cperl-continued-statement-offset: 4
# cperl-continued-brace-offset: -4
# cperl-brace-offset: 0
# cperl-label-offset: -2
# End: