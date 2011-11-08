#!/usr/bin/env perl
use strict;
use warnings;
use AnyEvent::Pixiv::Download;
use Config::Pit;
use Web::Scraper;
use YAML;

sub _scrape {
    my $html = shift;
    my $scraper = scraper {
        process '/html/body/div[@id="wrapper"]/div[@id="page-bookmark"]//form[@id="f"]/div[2]/ul/li', 'lis[]' => scraper {
            process 'a', 'href' => [ '@href', sub { return "http://www.pixiv.net/" . $_ }];
        };
    };
    return $scraper->scrape($html)->{lis};
}

my $conf = pit_get('www.pixiv.net', require => {
    pixiv_id => '', pass => '',
});

my $cv = AE::cv;
my $client = AnyEvent::Pixiv::Download->new(
    pixiv_id => $conf->{pixiv_id}, pass => $conf->{pass},
);

$client->get("http://www.pixiv.net/bookmark.php?p=1", sub {
    my($body, undef) = @_;
    my $lis = _scrape($body);

    for (@{$lis}) {
        my $illust_id = ($_->{href} =~ /illust_id=(\d+)$/)[0];

        $client->prepare_download($illust_id, 'deep', sub {
            my $inf = shift;

            for my $img_src (@{$inf->{contents}}) {
                $cv->begin;

                $client->download($img_src, $illust_id, sub {
                    my(undef, $headers) = @_;
                    warn $headers->{URL};
                    $cv->end;
                });
            }
        });
    }
});

$cv->recv;
print Dump $client->{information_mode_medium};

