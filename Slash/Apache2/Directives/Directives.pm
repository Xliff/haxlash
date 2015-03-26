# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2005 by Open Source Technology Group. See README
# and COPYING for more information, or see http://slashcode.com/.

package Slash::Apache2::Directives;

use strict;
use Time::HiRes;
use Apache2;
use Apache2::Const qw(:common :cmd_how :override);
use Apache2::CmdParms ();
use Apache2::Module ();
use Apache2::Directive ();
use Slash::DB;
use Slash::Display;
use Slash::Utility;
use URI;

use vars qw($VERSION $USER_MATCH $DAYPASS_MATCH);

$VERSION   	= '2.003000';  # v2.3.0

$USER_MATCH = qr{ \buser=(?!	# must have user, but NOT ...
	(?: nobody | %[20]0 )?	# nobody or space or null or nothing ...
	(?: \s | ; | $ )	# followed by whitespace, ;, or EOS
)}x;
$DAYPASS_MATCH = qr{\bdaypassconfcode=};

# Declare custom directives
my @directives = (
	{
		name		=> 'SlashVirtualUser',
		func		=> __PACKAGE__ . '::SlashVirtualUser',
		errmsg          => 'Takes a DBIx::Password virtual name',
		args_how        => TAKE1,
		req_override    => RSRC_CONF
        },

        {
		name            => 'SlashSetVar',
		func		=> __PACKAGE__ . '::SlashSetVar',
        	errmsg          => 'Takes a key and a value that will override the var values in the DB',
        	args_how        => TAKE2,
        	req_override    => RSRC_CONF
        },

        {
		name            => 'SlashSetForm',
		func		=> __PACKAGE__ . '::SlashSetForm',
        	errmsg          => 'Takes a key and a value that will be applied to each form object',
        	args_how        => TAKE2,
        	req_override    => RSRC_CONF
        },

#        {
#		name            => 'SlashSetVarHost',
#		func		=> __PACKAGE__ . '::SlashSetVarHost',
#        	errmsg          => 'Takes a key, a value, and a hostname that will override the var values in the DB for a specific hostname',
#        	args_how        => TAKE3,
#        	req_override    => RSRC_CONF
#        },

#        {
#		name            => 'SlashSetFormHost',
#		func		=> __PACKAGE__ . '::SlashSetFormHost',
#       	errmsg          => 'Takes a key, a value, and a hostname that will be applied to each form object for a specific hostname',
#		args_how        => TAKE3,
#	        req_override    => RSRC_CONF
#        }, 

	 {
		name            => 'SlashCompileTemplates',
		func		=> __PACKAGE__ . '::SlashCompileTemplates',
        	errmsg          => 'Turn precompiling templates on or off',
		args_how        => FLAG,
        	req_override    => RSRC_CONF
         },

#        {
#		name            => 'SlashSectionHost',
#		func		=>__PACKAGE__ . '::SlashSectionHost',
#        	errmsg          => 'Associate a host with a given section name',
#        	args_how        => TAKE2,
#	        req_override    => RSRC_CONF
#        }
);

Apache2::Module::add(__PACKAGE__, \@directives);

# BENDER: There's nothing wrong with murder, just as long
# as you let Bender whet his beak.

sub SlashVirtualUser ($$$) {
	my($cfg, $params, $user) = @_;

	# In case someone calls SlashSetVar before we have done the big mojo -Brian
	my $overrides = $cfg->{constants};

	createCurrentVirtualUser($cfg->{VirtualUser} = $user);
	createCurrentDB		($cfg->{slashdb} = Slash::DB->new($user));
	createCurrentStatic(
		$cfg->{constants} = $cfg->{slashdb}->getSlashConf(0),
	        $cfg->{constants_secure} = $cfg->{slashdb}->getSlashConf(1)
	);

	# placeholders ... store extra placeholders in DB?  :)
	for (qw[user form themes template cookie objects cache site_constants]) {
		$cfg->{$_} = '';
	}

	$cfg->{constants}{form_override} ||= {};
	# This has to be a hash
	$cfg->{site_constants} = {};

	if ($overrides) {
		@{$cfg->{constants}}{keys %$overrides} = values %$overrides;
	}

	my $anonymous_coward = $cfg->{slashdb}->getUser(
		$cfg->{constants}{anonymous_coward_uid}
	);

	# Let's just do this once
	setUserDate($anonymous_coward);

	createCurrentAnonymousCoward($cfg->{anonymous_coward} = $anonymous_coward);
	createCurrentUser($anonymous_coward);

	$cfg->{menus} = $cfg->{slashdb}->getMenus();

	########################################
	# Skip the nonsense that used to be here.  Previously we
	# were copying the whole set of constants, and then putting
	# sectional data into it as well, for each section that had
	# a hostname defined.  First of all, of course, sections
	# have become skins so the data can be found in getSkin().
	# But also, we're not doing this stuff with separate sets of
	# constants for each hostname.  Because the skin-specific
	# data is split off into getSkin()'s hashref, we only need
	# one set of data for $constants.  These fields were moved
	# from constants to skins:
	# absolutedir, rootdir, cookiedomain, defaulttopic,
	# defaultdisplaystatus, defaultcommentstatus,
	# basedomain, index_handler, and though I'm not sure
	# it was ever used, absolutedir_secure.
	# These fields are gone because they are now obviated:
	# defaultsubsection, defaultsection, static_section.
	########################################

	$cfg->{slashdb}->{_dbh}->disconnect if $cfg->{slashdb}->{_dbh};
}

sub SlashSetVar ($$$$) {
	my($cfg, $params, $key, $value) = @_;
	unless ($cfg->{constants}) {
		print STDERR "SlashSetVar must be called after call SlashVirtualUser \n";
		exit(1);
	}
	$cfg->{constants}{$key} = $value;
}

sub SlashSetForm ($$$$) {
	my($cfg, $params, $key, $value) = @_;
	unless ($cfg->{constants}) {
		print STDERR "SlashSetForm must be called after call SlashVirtualUser \n";
		exit(1);
	}
	$cfg->{constants}{form_override}{$key} = $value;
}

#sub SlashSetVarHost ($$$$$) {
#	my($cfg, $params, $key, $value, $hostname) = @_;
#	unless ($cfg->{constants}) {
#		print STDERR "SlashSetVarHost must be called after call SlashVirtualUser \n";
#		exit(1);
#	}
#	my $new_cfg;
#	for (keys %{$cfg->{constants}}) {
#		$new_cfg->{$_} = $cfg->{constants}{$_}
#			unless $_ eq 'form_override';
#	}
#	$new_cfg->{$key} = $value;
#	$cfg->{site_constants}{$hostname} = $new_cfg;
#}
#
#sub SlashSetFormHost ($$$$$) {
#	my($cfg, $params, $key, $value, $hostname) = @_;
#	unless ($cfg->{constants}) {
#		print STDERR "SlashSetFormHost must be called after call SlashVirtualUser \n";
#		exit(1);
#	}
#	my $new_cfg;
#	for (keys %{$cfg->{constants}}) {
#		$new_cfg->{$_} = $cfg->{constants}{$_}
#			unless $_ eq 'form_override';
#	}
#	$new_cfg->{form_override}{$key} = $value;
#	$cfg->{site_constants}{$hostname} = $new_cfg;
#}
#
#sub SlashSectionHost ($$$$) {
#	my($cfg, $params, $section, $url)  = @_;
#	my $hostname = $url;
#	$hostname =~ s/.*\/\///;
#	unless ($cfg->{constants}) {
#		print STDERR "SlashSectionHost must be called after call SlashVirtualUser \n";
#		exit(1);
#	}
#	# Yes, this looks slower then the other method but I was getting different results.
#	# Bad results, and it's Friday. Bad results on Friday is a bad thing.
#	# -Brian
#	my $new_cfg;
#	for (keys %{$cfg->{constants}}) {
#		$new_cfg->{$_} = $cfg->{constants}{$_}
#			unless $_ eq 'form_override';
#	}
#	# Must not just copy the form_override info
#	$new_cfg->{form_override} = {};
#	$new_cfg->{absolutedir} = $url;
#	$new_cfg->{absolutedir_secure} = set_rootdir($url, $cfg->{constants}{absolutedir_secure});
#	$new_cfg->{rootdir} = set_rootdir($url, $cfg->{constants}{rootdir});
#	$new_cfg->{basedomain} = $hostname;
#	$new_cfg->{defaultsection} = $section;
#	$new_cfg->{static_section} = $section;
#	# Should no longer be needed -Brian
#	#$new_cfg->{form_override}{section} = $section;
#	$cfg->{site_constants}{$hostname} = $new_cfg;
#}

sub SlashCompileTemplates ($$$) {
	my($cfg, $params, $flag) = @_;
	return unless $flag;

	# set up defaults
	my $slashdb	= $cfg->{slashdb};
	my $constants	= $cfg->{constants};

	# caching must be on, along with unlimited cache size
	return unless $constants->{cache_enabled}
		  && !$constants->{template_cache_size};

	my $start_time = Time::HiRes::time;
	my $begin_printed = 0;
	my $elapsed_time = 0;

	my $templates = $slashdb->getTemplateNameCache();

	# temporarily turn off warnings and errors, see errorLog()
	# This is normally considered a big no no inside of Apache
	# since how will its own signal handlers be put back in place?
	# -Brian
	# what do you mean, put back in place?  when the function
	# finishes, they are all automatically reverted, because
	# of local() -- pudge
	local $Slash::Utility::NO_ERROR_LOG = 1;
	local $SIG{__WARN__} = 'IGNORE';
	local $slashdb->{_dbh}{PrintError};

	# this will call every template in turn, and it will
	# then be compiled; now, we will get errors in
	# the error log for templates that don't check
	# the input values; that can't easily be helped
	my @templates = ( );
	for my $name (sort keys %$templates) {
		for my $page (sort keys %{$templates->{$name}}) {
			for my $skin (sort keys %{$templates->{$name}{$page}}) {
				push @templates, [$name, $page, $skin];
			}
		}
	}
	for my $i (0..$#templates) {
		my($name, $page, $skin) = @{$templates[$i]};
		slashDisplay($name, 0, {
			Page	=> $page,
			Skin	=> $skin,
			Return	=> 1,
			Nocomm	=> 1
		});
		$elapsed_time = Time::HiRes::time - $start_time;
		if (!$begin_printed
			&& ( $i < $#templates * 0.5 && $elapsed_time > 6 * 0.5
			  || $i > 2 && $elapsed_time * $#templates / $i > 6	)
		) {
			# Only bother to print the begin (and done) message
			# if this is taking a while and we're not almost done
			# anyway.
			printf STDERR "%s (%d): Compiling All Templates Begin\n",
				$cfg->{VirtualUser}, $$;
			$begin_printed = 1;
		}
	}

	printf STDERR "%s (%d): Compiling All Templates Done in %0.3f secs\n",
		$cfg->{VirtualUser}, $$, Time::HiRes::time - $start_time
		if $begin_printed;

	$cfg->{template} = Slash::Display::get_template(0, 0, 1);
	# let's make sure
	$slashdb->{_dbh}->disconnect;
}

sub DESTROY { }


1;

__END__

=head1 NAME

Slash::Apache2::Directives - Custom Apache Directives for Slash

=head1 SYNOPSIS

	PerlLoadModule Slash::Apache2::Directives;

=head1 DESCRIPTION

This is what creates the SlashVirtualUser command for us
in the httpd.conf file.

=head1 SEE ALSO

Slash(3).

=cut
