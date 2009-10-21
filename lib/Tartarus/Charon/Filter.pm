use strict;
package Tartarus::Charon::Filter;

use Time::Local;
use feature qw/say/;

our $filename_re = qr/^tartarus-
    (?<profile>[^-]+)-
    (?<date>[0-9]{4}[01][0-9][0-3][0-9]-[012][0-9][0-9]{2})
    (?:\.|-inc-(?<basedate>[0-9]{4}[01][0-9][0-3][0-9]-[012][0-9][0-9]{2}))?
    \.(?<chunk>chunk-[0-9]+\.)?(tar|afio)
/x;

sub new {
    my ($proto) = @_;
    my $class = ref $proto || $proto;
    my $self = {};
    $self->{files} = {};
    $self->{verbose} = 0;

    bless $self, $class;
}

sub verbose {
    my ($self, $flag) = @_;
    if (defined $flag) {
        $self->{verbose} = $flag;
    }
    return $self->{verbose};
}

sub files {
    my $self = shift;

    for my $filename (@_) {
        if ($filename =~ $filename_re) {
            $self->{files}{$filename} = 1;
        } else {
            say STDERR "Unable to handle '$filename'";
        }
    }

    return sort keys %{$self->{files}};
}

sub __string2time {
    my ($time) = @_;

    if ($time =~ /^([0-9]{4})([01][0-9])([0-3][0-9])-([012][0-9])([0-9]{2})$/) {
        my $t = timelocal(0, $5, $4, $3, $2-1, $1);
        return $t;
    }
}


sub expire {
    my ($self, $days, $only_profile) = @_;
    my %delete = ();
    
    my $preserve;
    $preserve = sub {
        my ($profile, $date) = @_;
        return unless $delete{$profile}{$date}{expired};
        $delete{$profile}{$date}{expired} = 1;
        
        if ($delete{$profile}{$date}{base}) {
            say STDERR "Preserving $profile-".$delete{$profile}{$date}{base}." for $profile-$date" if $self->verbose;
            &{$preserve}( $profile, $delete{$profile}{$date}{base} );
        }
        delete $delete{$profile}{$date};
    };

    for my $filename ($self->files) {
        next unless ($filename =~ $filename_re);
        my $profile = $+{profile};
        next if (defined $only_profile && $profile ne $only_profile);

        my $date = $+{date};
        my $based_on = $+{basedate};
        my $inc = defined $based_on;
        
        # construct tree node
        $delete{$profile}{$date}{base} = $based_on;
        push @{$delete{$profile}{$date}{files}}, $filename;
        $delete{$profile}{$date}{expired} = 1;

        my $age = int( ( time - __string2time($date) ) / (60*60*24) );

        if ($age > $days) {
            say STDERR "$filename is $age days old, scheduling for deletion" if $self->verbose;
        } else {
            # If it is an incremental backup, we have to preserve the backup it is based on
            &$preserve( $profile, $date );
        }
    }
    
    # return expired files
    my @expire = ();
    for my $p (values %delete) {
        for my $a (values %$p) {
            push @expire, @{$a->{files}} if $a->{expired};
        }
    }
    return @expire;
}

1;
