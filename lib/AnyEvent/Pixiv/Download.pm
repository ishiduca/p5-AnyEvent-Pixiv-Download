package AnyEvent::Pixiv::Download;

use warnings;
use strict;
use Carp;
use AnyEvent;
use AnyEvent::HTTP;
use Web::Scraper;
use File::Basename;
use YAML;

our $VERSION = '0.04';

my $www_pixiv_net = 'http://www.pixiv.net';
my $login_php     = "${www_pixiv_net}/login.php";
my $mypage_php    = "${www_pixiv_net}/mypage.php";
my $illust_top    = "${www_pixiv_net}/member_illust.php?mode=medium&illust_id=";

sub new {
    my $class = shift;
    my %args  = @_;

    my $self  = bless {}, $class;

    $self->{pixiv_id} = delete $args{pixiv_id} || Carp::croak qq(! faild: "pixiv_id" not found);
    $self->{pass}     = delete $args{pass}     || Carp::croak qq(! failed: "pass" not found);
    $self->{verbose}  = delete $args{verbose}  || 1;
    $self->{retry}    = delete $args{retry}    || 3;
    #$self->{cookie_jar} = {};
    #$self->{information_mode_medium} = {};

    $self->login;

    return $self;
}

sub login {
    my $self = shift;

    $self->{pixiv_id} or Carp::croak qq(! failed: "pixiv_id" not found\n);
    $self->{pass}     or Carp::croak qq(! failed: "pass" not found\n);

    my $sub_cv = AE::cv;
    my $login; $login = http_request('POST' => $login_php,
        headers => { 'content-type' => 'application/x-www-form-urlencoded' },
        body    => "mode=login&pixiv_id=$self->{pixiv_id}&pass=$self->{pass}",
        recurse => 0,
        sub {
            my($body, $headers) = @_;
            warn YAML::Dump $headers         if $self->{verbose} == 2;
            warn qq(fetch: "${login_php}"\n) if $self->{verbose} == 1;

            Carp::croak qq(! failed: "set-cookie" not found at $headers->{URL}\n)
                unless $headers->{'set-cookie'};

            $self->{cookie_jar} = _cookie_jar_hogehoge($headers->{'set-cookie'})
                or Carp::croak qq(! failed: something wrong...\n);

            warn YAML::Dump $self->{cookie_jar}               if $self->{verbose} == 2;
            warn qq(get_cookie: "$headers->{'set-cookie'}"\n) if $self->{verbose} == 1;

            my $location = $headers->{'location'};

            undef $login;

            my $redirect; $redirect = http_request('GET' => $location,
                cookie_jar => $self->{cookie_jar},
                sub {    
                    my($body, $headers) = @_;
                    Carp::croak qq(! failed: "redirect" failed\n  $headers->{URL}\n)
                        if $headers->{URL} ne $location;

                    warn YAML::Dump $headers            if $self->{verbose} == 2;
                    warn qq(fetch: "$headers->{URL}"\n) if $self->{verbose} == 1;
                    
                    undef $redirect;
                    $sub_cv->send("ok : login !\n");
                }
            );
        }
    );
    my $message = $sub_cv->recv;
    warn $message;

    return $self;
}

sub prepare_download {
    my $self      = shift;
    my $cb        = pop;
    my $illust_id = shift || Carp::croak qq(! failed: "illust_id" not found\n);
    my $deep      = shift;

    $self->login unless $self->{cookie_jar};

    my $mode_medium; $mode_medium = http_request('GET', "${illust_top}${illust_id}",
        cookie_jar => $self->{cookie_jar},
        sub {
            my($body, $headers) = @_;
            warn YAML::Dump $headers            if $self->{verbose} == 2;
            warn qq(fetch: "$headers->{URL}"\n) if $self->{verbose} == 1;

            Carp::croak qq(! failed: something wrong...\n  $headers->{URL}\n)
                if $headers->{URL} ne "${illust_top}${illust_id}";

            my $information  = _scrape_mode_medium($body, $headers->{URL});

            if ($deep) {
                my $mode_big; $mode_big = http_request('GET', $information->{contents_url},
                    cookie_jar => $self->{cookie_jar},
                    headers    => { referer => $headers->{URL} },
                    sub {
                        my($body, $headers) = @_;

                        Carp::croak qq(! failed: something wrong...\n  $headers->{URL}\n)
                            if $headers->{URL} ne $information->{contents_url};

                        warn YAML::Dump $headers            if $self->{verbose} == 2;
                        warn qq(fetch: "$headers->{URL}"\n) if $self->{verbose} == 1;

                        if ($information->{contents_url} =~ /mode=manga/) {
                            $information->{mode} = 'manga';
                            $information->{contents} = [];
                            while ($body =~ m!(http://img\d\d\.pixiv\.net/img/[^']+?)'!g) {
                                push @{$information->{contents}}, $1;
                            }
                        } else { # $information->{contents_url} =~ /mode=big/
                            $information->{mode} = 'big';
                            my $scraper = scraper {
                                process '//div/a/img[1]', 'img_src' => '@src';
                            };
                            $information->{contents} = [ ($scraper->scrape($body))->{img_src} ];
                        }

                        $self->{information_mode_medium}->{$illust_id} = $information;
                        warn YAML::Dump $information if $self->{verbose} == 2;
                        #warn YAML::Dump $information if $self->{verbose} == 1;

                        undef $mode_big;
                        undef $mode_medium;
                        $cb->($information);
                    }
                );
            } else {
                $self->{information_mode_medium}->{$illust_id} = $information;
                warn YAML::Dump $information if $self->{verbose} == 2;
                #warn YAML::Dump $information if $self->{verbose} == 1;

                undef $mode_medium;
                $cb->($information);
            }
        }
    );

    return $self;
}

sub download {
    my $self      = shift;
    my $cb        = pop;
    my $img_src   = shift || Carp::croak qq(! failed: "img_src" not found\n);;
    my $illust_id = shift || Carp::croak qq(! failed: "illust_id" not found\n);
    my $options   = shift;

    my $c = $self->{retry};
    my($voodoo, $done, $on_body, $on_header, $cb_);

    $on_header = ($options->{on_header}) ? $options->{on_header} : sub {
        my $headers = shift;
        if ($headers->{Status} ne '200') {
            ($options->{on_error} || sub { die @_ })->(qq(failed: "${img_src}" $headers->{Status} $headers->{Reason}\n));
            return ;
        }
        return 1;
    };

    $on_body = ($options->{on_body}) ? $options->{on_body} : (sub {
        my $filename = (basename($img_src) =~ /^([^\?]+)/)[0];
        open my $fh, '>', $filename or Carp::croak qq(! failed: "${filename}" $!\n);
        binmode $fh;
        return sub {
            my($partial_body, $headers) = @_;
            if ($headers->{Status} =~ /^2/) {
                print $fh $partial_body;
            }
            return 1;
        };
    })->();

    $cb_ = sub {
        my($body, $headers) = @_;
        undef $done;
        if (!($headers->{'content-length'} > 0)  && $c > 0) {
            --$c;
            my $timer; $timer  = AE::timer 1, 1, sub {
                undef $timer;
                $voodoo->();
                return;
            };
        } else {
            $cb->(@_);
        }
    };

    $voodoo = sub {
        warn qq( --> try ${c}/$self->{retry} times: "${img_src}"\n) if $self->{verbose} > 0;
        $self->login unless $self->{cookie_jar};

        $done = http_request('GET' => $img_src,
            cookie_jar => $self->{cookie_jar},
            headers    => { referer => $self->{information_mode_medium}->{$illust_id}->{illust_top_url} },
            on_header  => $on_header,
            on_body    => $on_body,
            $cb_
        );
    };

    $voodoo->();

    return $self;
}

sub _scrape_mode_medium {
    my $body           = shift || Carp::croak qq(! failed: "body" not found\n);
    my $illust_top_url = shift || Carp::croak qq(! failed: "illust_top_url" not found\n);

    my $scraper = scraper {
        process '//h3[1]', 'title' => 'TEXT';
        process '//p[@class="works_caption"]', 'description' => 'HTML';
        process '//a[@class="avatar_m"]', 'author_name' => '@title';
        process '//a[@class="avatar_m"]', 'author_url'  => [ '@href', sub {
            return $www_pixiv_net . $_;
        } ];
        process '//div[@class="works_display"]/a[1]', 'contents_url' => [ '@href', sub {
            return join '/', $www_pixiv_net, $_;
        } ];
        process '//div[@class="works_display"]/a[1]/img[1]', 'img_src' => '@src';
    };

    my $information = $scraper->scrape($body);
    $information->{author} = {};
    $information->{author}->{name} = delete $information->{author_name};
    $information->{author}->{url}  = delete $information->{author_url};
    $information->{illust_top_url} = $illust_top_url;
    return $information;
}

sub _cookie_jar_hogehoge {
    local $_ = shift || return ;
    my %cookie = ();
    my $phpsessid = 'PHPSESSID';
    map{
        my($key, $value) = split /=/;
        $cookie{$key} = $value;
    }(split /; /);

    Carp::croak  qq(! failed: "${phpsessid}" not found) unless $cookie{$phpsessid};

    return {
        $cookie{domain} => {
            $cookie{path} => {
                $phpsessid => {
                    _expires => AnyEvent::HTTP::parse_date $cookie{expires},
                    value    => $cookie{$phpsessid},
                },
            },
        },
        version => 1,
    };
}


1;

__END__


=head1 NAME

AnyEvent::Pixiv::Download - the interface downloading any works from www.pixiv.net, based on AnyEvent.


=head1 SYNOPSIS

  use AnyEvent::Pixiv::Download;

  my $cv = AE::cv;
  my $client = AnyEvent::Pixiv::Download->new(
      pixiv_id => $config->{pixiv_id},
      pass     => $config->{pass},
  );

  my @illust_ids = qw/ 12345678 11801801 2543999 /;

  for my $illust_id (@illust_ids) {
      $client->prepare_download($illust_id, 'deep', sub {
          my $information = shift;

          for my $img_src (@{$information->{contents}}) {
              $cv->begin;
              $client->download($img_src, $illust_id, sub {
                  my(undef, $headers) = @_;
                  warn "!! finish ", $headers->{URL}, "\n";
                  $cv->end;
              });
          }
      }
  }

  $cv->recv;
  
    
=head1 DESCRIPTION

This module provides the interface downloading any works from www.pixiv.net based on AnyEvent.


=head1 METHODS

=over

=item B<new>

  $client = AnyEvent::Pixiv::Download->new(%options);

Creates a AnyEvent::Pixiv::Download instance. this client use L<AnyEvent::HTTP>.

=item pixiv_id, pass

These parameters ase required to login.

=item verbose, retry

These parameters are set as needed.
"verbose" is specified as a number of criteria to show the client the work process
 "0", the client does not display a process.
 "1", show fetching process, "2", more detail process.


=item B<login>

if cookie expired, use this method.


=item B<prepare_download($illust_id[, 'deep'], \&cb)>

  $client->prepare_download('12345678', 'deep', sub {
      my $information = shift;
      ....
  });

This method get a information about the work,
 and set a callback function to use that information.

The first parameter "illust_id" is passed to www.pixiv.net.
The second parameter is option parameter. set "deep" to this parameter, to get path to the images of original size.
The last parameter is callback function. this called when the client get the information of the work. the parameter of this callback function is some informations of this work. this parameter "information" is a hash reference. see below, about "information". 
This callback function is required.

=item $information

if used YAML::Dump then
---
  author:
    name: author name
    url: http://www.pixiv.net/member.php?id=user_id_number
    contents:
      - http://imgNN.pixiv.net/img/user_id/origin_size_img.src
    contents_url: http://www.pixiv.net/member_illust.php?mode=(manga|big)&illust_id=12345678
    description: description of works
    illust_top_url: http://www.pixiv.net/member_illust.php?mode=medium&illust_id=12345678
    img_src: http://imgNN.pixiv.net/img/user_id/medium_size_img.src
    mode: (manga|big)
    title: title of works


=item B<download($img_src, $illust_id, \%options, \&cb)>

This method provides a way to download a image and save it.
The first parameter is required. this parameter is the image's uri.
The second parameter is required too. this parameter is the illust_id.
The third parameter is option. third parameter is a hash reference. this hashref's key "on_body", "on_error", "on_header". see L<AnyEvent::HTTP>::http_request for details.
The last parameter is required. this parameter is a callback function. this callback function called when the image is finished downloading. this callback function will use two parameters "body" and "headers". see L<AnyEvent::HTTP> for details.

  use Path::Class    qw(dir);
  use File::Basename qw(basename);

  $client->prepare_download($illust_id, 'deep', sub {
      my $information = shift;

      unless (-e $illust_id) {
          warn qq(! directry "${illust_id}" not found\n);
          dir($illust_id)->mkpath or die qq(! failed: can not mkpath "${illust_id}"\n);
          warn qq(  success: mkpath "${illust_id}"\n);
      }

      for my $img_src (@{$information->{contents}}) {
          $cv->begin;

          my $filename = (basename($img_src) =~ /^([^\?]+)/)[0];
          my $path     = "$illust_id/$filename";
          open my $fh, '>', $path or die qq(! failed: "$path" $!);
          binmode $fh;

          $client->download($img_src, $illust_id,
              {
                  on_body => sub {
                      my($partial_body, $headers) = @_;
                      if ($headers->{Status} =~ /^2/) {
                          print $fh $partial_body;
                      }
                      1;
                  },
              }, sub {
                  my(undef, $headers) = @_;
                  warn "!! finish download: ", $headers->{URL}, "\n";
                  $cv->end;
              }
          );
      }
  });


=back

=head1 AUTHOR

ishiduca


=head1 SEE ALSO

L<AnyEvent>, L<AnyEvent::HTTP>


=head1 LICENCE

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

=cut




