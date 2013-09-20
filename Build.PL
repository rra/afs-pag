#!/usr/bin/perl
#
# Build script for the AFS::PAG distribution.
#
# Written by Russ Allbery <rra@stanford.edu>
# Copyright 2013
#     The Board of Trustees of the Leland Stanford Junior University
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

use 5.010;
use autodie;
use strict;
use warnings;

use Config::AutoConf;
use File::Basename qw(basename);
use File::Path qw(remove_tree);
use File::Spec;
use Module::Build;

# Returns C code that includes the given headers.  Used to construct prologues
# for check functions.
#
# @headers - The headers to include
#
# Returns: C source as a string that includes those headers
sub include {
    my @headers = @_;
    my $result  = q{};
    for my $header (@headers) {
        $result .= "#include <$header>\n";
    }
    return $result;
}

# Probes the C compilation environment for the information required to build
# the embedded libkafs compatibility layer.  This should be a Perl equivalent
# of the m4/kafs.m4 Autoconf macros from rra-c-util, plus the additional
# probes needed for the compatibility layer for building the cod.  Writes the
# results to glue/config.h and returns a list of extra C files to add to the
# module build.
#
# $build - The module build object, used to add additional libraries
#
# Returns: List of extra directories to add to the module build
#  Throws: Text exception if the module cannot be built in this environment
sub config_kafs {
    my ($build) = @_;
    my $config = Config::AutoConf->new;

    # Checks needed for the generic portability layer.
    $config->check_default_headers;
    if (!$config->check_header('stdbool.h')) {
        $config->check_type('_Bool');
    }
    $config->check_type('sig_atomic_t', undef, undef,
        include(qw(sys/types.h signal.h)));
    $config->check_type('ssize_t', undef, undef, include('sys/types.h'));

    # Checks needed by all libkafs code.
    $config->check_header('sys/ioccom.h');

    # If the user passed extra flags into Build.PL, use them for probes.
    if ($build->extra_linker_flags) {
        my $flags = $build->extra_linker_flags;
        my @flags = ref($flags) ? @{$flags} : ($flags);
        $config->push_link_flags(@flags);
    }

    # Check if we have a library available to us.  If so, check whether it
    # provides k_pioctl and k_haspag and then return.
    my $lib = $config->search_libs('k_hasafs', ['kafs', 'kopenafs']);
    my @files;
    if ($lib) {
        my $flags = $build->extra_linker_flags;
        my @flags = ref($flags) ? @{$flags} : ($flags);
        $build->extra_linker_flags(@flags, '-l' . $lib);
        if ($lib eq 'kafs') {
            $config->check_header('kafs.h');
        } elsif ($lib eq 'kopenafs') {
            $config->check_header('kopenafs.h');
        }
        if ($config->link_if_else($config->lang_call(q{}, 'k_pioctl'))) {
            $config->define_var('HAVE_K_PIOCTL', 1,
                'Define to 1 if you have the k_pioctl function');
        }
        if (!$config->link_if_else($config->lang_call(q{}, 'k_haspag'))) {
            @files = qw(portable/k_haspag.c);
        }
    } else {
        @files = qw(kafs/kafs.c portable/k_haspag.c);
        $config->define_var('HAVE_KAFS_REPLACEMENT', 1,
            'Define to 1 if the libkafs replacement is built.');
        $config->define_var('HAVE_KAFS_LINUX', 1,
            'Define to 1 to use the Linux AFS /proc interface.');
    }

    # Write out the configuration.
    $config->write_config_h('glue/config.h');

    # Return the list of files to add to the build.
    return @files;
}

# Basic package configuration.
my $build = Module::Build->new(
    module_name          => 'AFS::PAG',
    dist_version_from    => 'lib/AFS/PAG.pm',
    dist_author          => 'Russ Allbery <rra@stanford.edu>',
    license              => 'mit',
    recursive_test_files => 1,
    add_to_cleanup       => [qw(config.log cover_db glue/*.o)],

    # XS configuration.
    c_source             => 'glue',
    extra_compiler_flags => ['-I.'],

    # Other package relationships.
    configure_requires => {
        'Config::AutoConf' => 0,
        'Module::Build'    => '0.28',
        autodie            => 0,
        perl               => '5.010',
    },
    requires => {
        autodie => 0,
        perl    => '5.010',
    },
);

# Create the directory that will be used for config.h and stub files.
remove_tree('glue');
mkdir('glue');

# Write out the config.h file and get the list of files to add to the build.
my @c_files = config_kafs($build);

# We can't just add the C source files directly to the build for a couple of
# reasons.  First, Perl ships its own config.h, so we need to be sure we
# include our own instead of Perl's before building any source, since all of
# the files (copied from rra-c-util, so we don't want to change them) include
# config.h as the first action.  Second, Module::Build can only handle one
# directory of supplemental source files.
#
# We deal with both of these issues by creating stub files in a subdirectory
# named glue that include glue/config.h and then the actual C source file.
for my $file (@c_files) {
    my $glue_file = File::Spec->catfile('glue', basename($file));
    open(my $wrapper, '>', $glue_file);
    say {$wrapper} '#include <glue/config.h>'
      or die "Cannot write to $glue_file: $!\n";
    say {$wrapper} "#include <$file>"
      or die "Cannot write to $glue_file: $!\n";
    close($wrapper);
}

# Generate the build script.
$build->create_build_script;
