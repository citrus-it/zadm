package Zadm::Utils;
use Mojo::Base -base, -signatures;

use POSIX qw(isatty);
use Mojo::Exception;
use JSON::PP; # for pretty encoding and 'relaxed' decoding
use Mojo::Log;
use Mojo::File;
use Mojo::JSON qw(decode_json);
use Mojo::Message::Response;
use Mojo::Loader qw(find_modules);
use Mojo::Promise;
use Mojo::UserAgent;
use IO::Handle;
use IO::Uncompress::AnyUncompress qw($AnyUncompressError);
use IPC::Open3;
use File::Spec;
use File::Temp;
use Text::ParseWords qw(shellwords);
use Time::Piece;
use Sun::Solaris::Kstat;

# commands
my %CMDS = (
    zoneadm     => '/usr/sbin/zoneadm',
    zonecfg     => '/usr/sbin/zonecfg',
    zlogin      => '/usr/sbin/zlogin',
    zonename    => '/usr/bin/zonename',
    bhyvectl    => '/usr/sbin/bhyvectl',
    dladm       => '/usr/sbin/dladm',
    editor      => $ENV{VISUAL} || $ENV{EDITOR} || '/usr/bin/vi',
    zfs         => '/usr/sbin/zfs',
    pkg         => '/usr/bin/pkg',
    socat       => '/usr/bin/socat',
    nc          => '/usr/bin/nc',
    pager       => $ENV{PAGER} || '/usr/bin/less -eimnqX',
    domainname  => '/usr/bin/domainname',
    dispadmin   => '/usr/sbin/dispadmin',
    getconf     => '/usr/bin/getconf',
    pagesize    => '/usr/bin/pagesize',
    swap        => '/usr/sbin/swap',
    ipf         => '/usr/sbin/ipf',
    ipfstat     => '/usr/sbin/ipfstat',
    ipmon       => '/usr/sbin/ipmon',
    ipnat       => '/usr/sbin/ipnat',
);

my %ENVARGS = map {
    $_ => [ shellwords($ENV{'__ZADM_' . uc ($_) . '_ARGS'} // '') ]
} keys %CMDS;

my $ZPATH = ($ENV{__ZADM_ALTROOT} // '') . '/etc/zones';

my $progStr = sub($self, $bytes, $elapsed, $len = 0) {
    my $rate = $bytes / $elapsed;

    $len && return sprintf ('%s/%s %s [%s/s] [ETA: %-8s]',
        $self->prettySize($bytes, '%.0f%s', [ qw(b KiB MiB GiB TiB PiB) ]),
        $self->prettySize($len, '%.0f%s', [ qw(b KiB MiB GiB TiB PiB) ]),
        Time::Piece->new($elapsed)->hms,
        $self->prettySize($rate, '%.1f%s', [ qw(b KiB MiB GiB TiB PiB) ]),
        ($rate ? Time::Piece->new(($len - $bytes) / $rate)->hms : '-'));

    return sprintf ('%s %s [%s/s]',
        $self->prettySize($bytes, '%.0f%s', [ qw(b KiB MiB GiB TiB PiB) ]),
        Time::Piece->new($elapsed)->hms,
        $self->prettySize($rate, '%.1f%s', [ qw(b KiB MiB GiB TiB PiB) ]));
};

# attributes
has log      => sub { Mojo::Log->new(level => 'debug') };
has kstat    => sub { Sun::Solaris::Kstat->new };
has ua       => sub { Mojo::UserAgent->new->max_redirects(8) };
has uaprog   => sub($self) {
    my $ua = $self->ua->new;

    $ua->on(start => sub($ua, $tx) {
        my $start = my $last = time;
        print 'Downloading ', $tx->req->url, "...\n";

        $tx->res->on(progress => sub($res) {
            my $now = time;
            if ($now > $last) {
                $last = $now;

                print "\r", $self->$progStr($res->content->progress,
                    $now - $start, $res->headers->content_length);
                STDOUT->flush;
            }
        });
        $tx->res->once(finish => sub($res) {
            print "\r", $self->$progStr($res->content->progress,
                time - $start, $res->headers->content_length), "\n";
            STDOUT->flush;
        });
    });

    return $ua;
};
has pagesize => sub($self) { $self->readProc('pagesize')->[0] // 4096 };
has ram      => sub($self) {
    return $self->kstat->{unix}->{0}->{system_pages}->{physmem}
        * $self->pagesize;
};
has swap     => sub($self) {
    my $swap = $self->readProc('swap', [ '-s' ])->[0]
        or return 0;

    my ($used, $avail) = $swap =~ /(\d+)k\s+used,\s+(\d+)k\s+available$/
        or return 0;

    return ($used + $avail) * 1024;
};

# private methods
my $edit = sub($self, $json) {
    my $fh = File::Temp->new(SUFFIX => '.json');
    close $fh;

    my $file = Mojo::File->new($fh->filename);
    $file->spurt($json);

    my $modified = $file->stat->mtime;

    local $@;
    eval {
        local $SIG{__DIE__};

        $self->exec('editor', [ $fh->filename ]);
    };
    if ($@) {
        # a return value of -1 indicats the editor could not be executed
        Mojo::Exception->throw("$@\n") if $? == -1;

        return (0, $json);
    }

    $json = $file->slurp;

    $modified = $file->stat->mtime != $modified;

    return ($modified, $json);
};

# public methods
sub readProc($self, $cmd, $args = []) {
    Mojo::Exception->throw("ERROR: command '$cmd' not defined.\n")
        if !exists $CMDS{$cmd};

    my @cmd = (shellwords($CMDS{$cmd}), @{$ENVARGS{$cmd}}, @$args);
    $self->log->debug("@cmd");

    open my $devnull, '>', File::Spec->devnull;
    my $pid = open3(undef, my $stdout, $devnull, @cmd);

    chomp (my @read = <$stdout>);

    waitpid $pid, 0;

    return \@read;
}

sub exec($self, $cmd, $args = [], $err = "executing '$cmd'", $fork = 0, $ret = 0) {
    Mojo::Exception->throw("ERROR: command '$cmd' not defined.\n")
        if !exists $CMDS{$cmd};

    my @cmd = (shellwords($CMDS{$cmd}), @{$ENVARGS{$cmd}}, @$args);
    $self->log->debug("@cmd");

    if ($fork) {
        if (defined (my $pid = fork)) {
            # exec should never return unless there was an error
            $pid || exec (@cmd)
                or Mojo::Exception->throw("ERROR: $err: $!\n");
        }
    }
    else {
        system (@cmd) && ($ret || Mojo::Exception->throw("ERROR: $err: $!\n"));
    }
}

sub curl($self, $files, $opts = {}) {
    return if !@$files;
    $self->log->debug("downloading $_->{url}...") for @$files;
    Mojo::Promise->all(
        map { $opts->{silent} ? $self->ua->get_p($_->{url}) : $self->uaprog->get_p($_->{url}) } @$files
    )->then(sub(@tx) {
        for (my $i = 0; $i <= $#$files; $i++) {
            my $res = $tx[$i]->[0]->result;

            if (!$res->is_success) {
                my $err = "ERROR: Failed to download file from $files->[$i]->{url} - "
                    . $res->code . ' ' . $res->default_message . "\n";

                Mojo::Exception->throw($err) if $opts->{fatal};
                print STDERR $err;

                next;
            }

            local $@;
            eval {
                local $SIG{__DIE__};

                $res->save_to($files->[$i]->{path});
            };

            if ($@) {
                my $err = "ERROR: Failed to write file to $files->[$i]->{path}.\n";
                Mojo::Exception->throw($err) if $opts->{fatal};
                print STDERR $err;
            }
        }
    })->catch(sub($err) {
        Mojo::Exception->throw($err) if $opts->{fatal};
        print STDERR $err;
    })->wait;
}

sub zfsRecv($self, $file, $ds) {
    my @cmd = ($CMDS{zfs}, qw(recv -Fv), $ds);

    $self->log->debug("@cmd");

    open my $zfs, '|-', @cmd or Mojo::Exception->throw("ERROR: receiving zfs stream: $!\n");
    my $decomp = IO::Uncompress::AnyUncompress->new($file->to_string)
        or Mojo::Exception->throw("ERROR: decompressing '$file' failed: $AnyUncompressError\n");

    my $bytes = 0;
    my $start = my $last = time;
    while (my $status = $decomp->read(my $buffer)) {
        Mojo::Exception->throw("ERROR: decompressing '$file' failed: $AnyUncompressError\n")
            if $status < 0;

        print $zfs $buffer;
        $bytes += $status;

        my $now = time;
        if ($now > $last) {
            $last = $now;

            print "\r", $self->$progStr($bytes, $now - $start);
            STDOUT->flush;
        }
    }
    print "\r", $self->$progStr($bytes, time - $start), "\n";
    STDOUT->flush;
}

sub encodeJSON($self, $data) {
    return JSON::PP->new->pretty->canonical(1)->encode($data);
}

sub edit($self, $zone, $prop = {}) {
    # backup current zone XML so it can be restored when things get hairy
    my $backcfg;
    my $backmod;

    my $xml = Mojo::File->new($ZPATH, $zone->name . '.xml');
    if (-r $xml) {
        $self->log->debug("backing up current zone config from $xml");

        $backmod = $xml->stat->mtime;
        $backcfg = $xml->slurp
    }

    my $istty = $self->isaTTY || $ENV{__ZADMTEST};
    my $json  = $self->encodeJSON($zone->config) if !%$prop && $istty;

    my $cfgValid = 0;

    while (!$cfgValid) {
        (my $mod, $json) = %$prop ? (1, '')
                         : $istty ? $self->$edit($json)
                         :          (1, join ("\n", @{$self->getSTDIN}));

        if (!$mod) {
            if ($zone->exists) {
                # restoring the zone XML config since it was changed but something went wrong
                if ($backmod && $backmod != $xml->stat->mtime) {
                    $self->log->warn('WARNING: restoring the zone config.');
                    $xml->spurt($backcfg);

                    return 0;
                }

                return 1;
            }

            print "You did not make any changes to the default configuration,\n",
                'do you want to create the zone with all defaults [Y/n]? ';
            chomp (my $check = <STDIN>);

            return 0 if $check =~ /^no?$/i;
        }

        local $@;
        $self->log->debug("validating JSON");
        my $cfg = eval {
            local $SIG{__DIE__};
            %$prop ? { %{$zone->config}, %$prop } : JSON::PP->new->relaxed(1)->decode($json);
        };
        if ($@) {
            my ($pre, $off, $post) = $@ =~ /^(.+at)\s+character\s+offset\s+(\d+)\s+(.+\))\s+at\s+/;

            if (defined $pre && defined $off && defined $post) {
                # cut the JSON string at the offset where decoding failed
                my $jsonerr = substr $json, 0, $off;
                # count newlines
                my $nl = $jsonerr =~ s/(?:\r\n|\n|\r)//sg;
                $@ = "$pre line " . ($nl + 1) . " $post\n";
            }
        }
        else {
            $self->log->debug("validating config");
            $cfgValid = eval {
                local $SIG{__DIE__};
                $zone->setConfig($cfg);
            };
        }
        if ($@) {
            print $@;

            my $check;
            if (!$istty || %$prop) {
                $check = 'no';
            }
            else {
                print 'Do you want to retry [Y/n]? ';
                chomp ($check = <STDIN>);
            }

            if ($check =~ /^no?$/i) {
                # restoring the zone XML config since it was changed but something went wrong
                if ($backmod && $backmod != $xml->stat->mtime) {
                    $self->log->warn('WARNING: restoring the zone config.');
                    $xml->spurt($backcfg);
                }

                return 0;
            }
        }
    }

    return 1;
}

sub getZfsProp($self, $ds, $prop = []) {
    return {} if !@$prop;

    my $vals = $self->readProc('zfs', [ qw(get -H -o value), join (',', @$prop), $ds ]);

    return { map { $prop->[$_] => $vals->[$_] } (0 .. $#$prop) };
}

sub domain($self) {
    my %domain;

    my ($domain) = $self->readProc('domainname')->[0] =~ /^\s*(\S+)/;

    -r '/etc/resolv.conf' && do {
        open my $fh, '<', '/etc/resolv.conf'
            or Mojo::Exception->throw("ERROR: cannot read /etc/resolv.conf: $!\n");

        while (<$fh>) {
            my ($key, $val) = /^\s*(\S+)\s+(\S+)/
                or next;

            for ($key) {
                /^nameserver$/ && do {
                    push @{$domain{resolvers}}, $val;

                    last;
                };
                /^domain$/ && do {
                    $domain{'dns-domain'} = $val;

                    last;
                };
                /^search$/ && do {
                    $domain{'dns-domain'} ||= $val;

                    last;
                };
            }
        }
    };

    $domain{'dns-domain'} = $domain if $domain;

    return \%domain;
}

sub scheduler($self) {
    my $dispadmin = $self->readProc('dispadmin', [ qw(-d) ]);

    return { 'cpu-shares' => 1 } if grep { /^FSS/ } @$dispadmin;
    return {};
}

sub prettySize($self, $size, $format = '%.0f%s', $units = [ qw(B K M G T P E) ]) {
    my $i = $size <= 0 ? 0 : int (log ($size) / log (1024.0));

    return sprintf($format, $size / 1024 ** $i, $units->[$i]);
}

sub getPhysMem($self) {
    return $self->prettySize($self->ram);
}

sub loadTemplate($self, $file, $name = '') {
    my $template = Mojo::File->new($file)->slurp;
    # TODO: add handler for more modular transforms, for now we just support __ZONENAME__
    $template =~ s/__ZONENAME__/$name/g if $name;

    # TODO: add proper error handling
    return JSON::PP->new->relaxed(1)->decode($template);
}

sub getOverLink($self) {
    my $dladm = $self->readProc('dladm', [ qw(show-link -p -o), 'link,class' ]);
    return [ map { /^([^:]+):(?:phys|etherstub|aggr|overlay)/ } @$dladm ];
}

sub isVirtual($self) {
    my $method = (caller (1))[3];

    Mojo::Exception->throw("ERROR: '$method' is a pure virtual method and must be implemented in a derived class.\n");
}

sub isaTTY($self) {
    return isatty(*STDIN);
}

sub getSTDIN($self) {
    return $self->isaTTY() ? [] : [ split /\r\n|\n|\r/, do { local $/; <STDIN>; } ];
}

sub genmap($self, $arr) {
    return { map { $_ => undef } @$arr };
}

sub getMods($self, $namespace) {
    return [ grep { !/base$/ } find_modules $namespace ];
}

1;

__END__

=head1 COPYRIGHT

Copyright 2021 OmniOS Community Edition (OmniOSce) Association.

=head1 LICENSE

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.
This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
more details.
You should have received a copy of the GNU General Public License along with
this program. If not, see L<http://www.gnu.org/licenses/>.

=head1 AUTHOR

S<Dominik Hassler E<lt>hadfl@omniosce.orgE<gt>>

=head1 HISTORY

2020-10-24 had Initial Version

=cut
