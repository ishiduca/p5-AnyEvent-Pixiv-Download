use strict;
use warnings;
use inc::Module::Install;

perl_version ('5.005');

all_from 'lib/AnyEvent/Pixiv/Download.pm';

requires 'AnyEvent';
requires 'AnyEvent::HTTP';
requires 'Web::Scraper';
requires 'File::Basename';
requires 'YAML';

test_requires 'Test::More';

auto_include_deps;

tests_recursive;

WriteAll;

