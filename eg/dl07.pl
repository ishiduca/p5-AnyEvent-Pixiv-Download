#!/usr/bin/env perl
use strict;
use warnings;
use lib '../lib';
use Config::Pit;
use AnyEvent::Pixiv::Download;
use Path::Class;
use File::Basename;

@ARGV or die qq("! faild: "arguments" not found\n  usage: $0 nnnnnnn NNNNNN\n);

my $config = pit_get('www.pixiv.net', require => {
    pixiv_id => '', pass => '',
});

my $cv = AE::cv;

my $client = AnyEvent::Pixiv::Download->new(
    pixiv_id => $config->{pixiv_id},
    pass     => $config->{pass},
);

for my $illust_id (@ARGV) {
    $client->prepare_download($illust_id, 'deep', sub {
        my $information = shift;

        unless (-e $illust_id) {
            warn qq(! dir "${illust_id}" not found\n);
            dir($illust_id)->mkpath or die qq(! failed: can not mkpath "${illust_id}"\n);
            warn qq(  success: mkpath "${illust_id}"\n);
        }

        for my $img_src (@{$information->{contents}}) {
            $cv->begin;
            $client->download($img_src, $illust_id, {
                on_body => (sub {
                    my $filename = (basename($img_src) =~ m/^([^\?]+)/)[0];
                    my $path = "${illust_id}/${filename}";
                    open my $fh, '>', $path or die qq(! failed: "${path}" $!\n);
                    binmode $fh;
                    return sub {
                        my($partial_body, $headers) = @_;
                        if ($headers->{Status} =~ /^2/) {
                            print $fh $partial_body;
                        }
                        1;
                    };
                })->(),
            }, sub {
                my(undef, $headers) = @_;
                warn "!! finish ", $headers->{URL}, "\n";
                $cv->end;
            });
        }
    });
}

$cv->recv;
use YAML;
print YAML::Dump $client->{information_mode_medium};
1;

