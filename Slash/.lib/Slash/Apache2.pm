# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2005 by Open Source Technology Group. See README
# and COPYING for more information, or see http://slashcode.com/.

package Slash::Apache2;

use strict;
use Time::HiRes;
use Apache2;
use Apache2::Const qw(:common);
use Apache2::RequestUtil ();
use Slash::DB;
use Slash::Utility;
use URI;

use vars qw($VERSION $USER_MATCH $DAYPASS_MATCH);

$VERSION   	= '2.003000';  # v2.3.0

$USER_MATCH = qr{ \buser=(?!	# must have user, but NOT ...
	(?: nobody | %[20]0 )?	# nobody or space or null or nothing ...
	(?: \s | ; | $ )	# followed by whitespace, ;, or EOS
)}x;
$DAYPASS_MATCH = qr{\bdaypassconfcode=};


# This handler is called in the first Apache phase, post-read-request.
#
# This can be used in conjunction with mod_proxy_add_forward or somesuch,
# if you use a frontend/backend Apache setup, where all requests come
# from 127.0.0.1 or some other predictable IP number(s).  For speed, we
# use a closure to store the regex that matches incoming IP number.
{
my $trusted_ip_regex = undef;
my $trusted_header = undef;
sub ProxyRemoteAddr ($) {
	my($r) = @_;

	# Set up the variables that are loaded only once.
	if (!defined($trusted_ip_regex) || !defined($trusted_header)) {
		my $constants = getCurrentStatic();
		$trusted_ip_regex = $constants->{clientip_xff_trust_regex};
		if ($trusted_ip_regex) {
			# Avoid a little processing each time by doing
			# the regex parsing just once.
			$trusted_ip_regex = qr{$trusted_ip_regex};
		} elsif (!defined($trusted_ip_regex)) {
			# If not defined, use localhost.
			$trusted_ip_regex = qr{^127\.0\.0\.1$};
		} else {
			# If defined but false, disable.
			$trusted_ip_regex = '0';
		}
		$trusted_header = $constants->{clientip_trust_header} || '';
	}

	# If the actual IP the connection came from is not trusted, we
	# skip the following processing.  An untrusted client could send
	# any header with any value.
	if ($trusted_ip_regex eq '0'
		|| $r->connection->remote_ip !~ $trusted_ip_regex) {
		return OK;
	}

	# The connection comes from a trusted IP.  Use either the
	# specified header (which presumably the trusted IP overwrites
	# or modifies) and pull from it the last IP on its list (so
	# presumably if the trusted IP does merely modify the header,
	# it appends the actual original IP to its value).
	my $xf = undef;
	$xf = $r->header_in($trusted_header) if $trusted_header;
	$xf ||= $r->header_in('X-Forwarded-For');
	if ($xf) {
		if (my($ip) = $xf =~ /([\d.]+)$/) {
			$r->connection->remote_ip($ip);
		}
	}

	return OK;
}
}

sub ConnectionIsSSL {
	# If the connection is made over an SSL connection, it's secure.
	# %ENV won't contain all its fields this early in mod_perl but
	# it's quick to check just in case.
	return 1 if $ENV{SSL_SESSION_ID};

	# That probably didn't work so let's get that data the hard way.
	my $r = Apache2::RequestUtil->request;
	return 0 if !$r;

	my $x = $r->header_in('X-SFINC-SSL');
	return 1 if $x && $x eq 'true';

	# This is a very expensive test and not one useful to us.
	# It is doubtful Slashdot will ever turn this back on.
#	my $subr = $r->lookup_uri($r->uri);
#	if ($subr) {
#		my $se = $subr->subprocess_env('HTTPS');
#		return 1 if $se && $se eq 'on'; # https is on
#	}

	$x = $r->header_in('X-SSL-On');
	return 1 if $x && $x eq 'yes'; 

	# We're out of ideas.  If the above didn't work we must not be
	# on SSL.
	return 0;
}

sub ConnectionIsSecure {
	return 1 if ConnectionIsSSL();

	# If the connection comes from a local IP or a network deemed
	# secure by the admin, it's secure.  (The too-clever-by-half
	# way of doing this would be to check this machine's routing
	# tables.  Instead we have the admins set a regex in a var.)
	my $r = Apache2::RequestUtil->request;
	my $ip = $r->connection->remote_ip;
	my $constants = getCurrentStatic();
	my $secure_ip_regex = $constants->{admin_secure_ip_regex};
	# Check the IP against the regex.  Assume we don't need to wrap
	# this in an "eval" -- it might break, but whoever set it should
	# know what they're doing.  Since this isn't s/// there's no 
	# chance of evaluating it, so this is not exploitable to gain
	# security or damage the site (beyond causing errors for every
	# click) even if it were compromised.
	return 1 if $secure_ip_regex && $ip =~ /$secure_ip_regex/;
 
	# Non-SSL connection, from a network not known to be secure.
	# Call it insecure.
	return 0;
}

sub IndexHandler {
	my($r) = @_;

	return DECLINED unless $r->is_main;
	my $constants = getCurrentStatic();

	#print STDERR scalar(localtime) . " $$ IndexHandler A\n";
	setCurrentSkin(determineCurrentSkin());
	my $gSkin     = getCurrentSkin();

	my $uri = $r->uri;
	my $cookie = $r->header_in('Cookie');
	my $is_user = $cookie =~ $USER_MATCH;
	my $has_daypass = 0;
	if (!$is_user) {
		if ($constants->{daypass} && $cookie =~ $DAYPASS_MATCH) {
			$has_daypass = 1;
		}
	}

	if ($gSkin->{rootdir}) {
		my $path = URI->new($gSkin->{rootdir})->path;
		$uri =~ s/^\Q$path//;
	}

	# Comment this in if you want to try having this do the right
	# thing dynamically
	# my $slashdb = getCurrentDB();
	# my $dbon = $slashdb->sqlConnect(); 
	my $dbon = dbAvailable();

	if ($uri eq '/' && $gSkin->{index_handler} ne 'IGNORE') {
		my $basedir = $constants->{basedir};

		# $USER_MATCH defined above
		if ($dbon && ($is_user || $has_daypass || $gSkin->{index_handler} =~ /^users/)) {
			$r->uri("/$gSkin->{index_handler}");
			$r->filename("$basedir/$gSkin->{index_handler}");
			return OK;
		} elsif (!$dbon) {
			# no db (you may wish to symlink index.shtml to your real
			# home page if you don't have one already)
			$r->uri('/index.shtml');
			return DECLINED;
		} else {
			# user not logged in

			# consider using File::Basename::basename() here
			# for more robustness, if it ever matters -- pudge
			my($base) = split(/\./, $gSkin->{index_handler});
			my $new_filename = "$base.shtml";

			# If index_anon_index_firehose is set, then anonymous users
			# get to see the firehose if appropriate -- overriding
			# the (non-users*) setting in the skin.
			if ($constants->{index_anon_index_firehose}) {
				my $ua = $r->header_in('User-Agent') || '';
				my $ua_type =
					  $ua =~ /MSIE [2-6]/ ? 'msie6'
					: $ua =~ /MSIE 7/     ? 'msie7'
					: $ua =~ /MSIE 8/     ? 'msie8'
					: $ua =~ /iPhone/     ? 'iphone'
					: $ua =~ /Firefox/    ? 'firefox'
					: $ua =~ /Safari/     ? 'safari'
					                      : 'other';
				$new_filename = $constants->{"index_anon_for_$ua_type"} || 'index2.pl';
			}

			my $new_filename_abs       = "$basedir/";
			my $new_uri                = '/';
			if ($gSkin->{skid} != $constants->{mainpage_skid}
				&& $new_filename =~ /\.shtml$/) {
				# Only handle subdirs for .shtml;  there aren't .pl
				# scripts in those subdirs.
				$new_filename_abs .= "$gSkin->{name}/";
				$new_uri          .= "$gSkin->{name}/";
			}
			$new_filename_abs         .= $new_filename;
			$new_uri                  .= $new_filename;

			$r->filename($new_filename_abs);
			$r->uri($new_uri);
			writeLog('shtml');
			return OK;
		}
	}

	# match /section/ or /section
	if ($uri =~ m|^/(\w+)/?$|) {
		my $key = $1;
		
		if (!$dbon) {
			$r->uri('/index.shtml');
			return DECLINED;
		}

		if ($key eq 'firehose') {
			$r->uri($is_user ? '/firehose.pl' : '/firehose.shtml');
			return OK;
		}

		my $slashdb = getCurrentDB();

		if ($constants->{plugin}{FireHose}) {
			my $fh_reader = getObject("Slash::FireHose", { db_type => 'reader'});

			my $fh_tabs = $fh_reader->getShortcutUserViews();

			if ($fh_tabs->{$key}) {
				$r->args("view=$key");
				$r->uri('/index2.pl');
				return OK;
			}
		}

		if ($constants->{plugin}{Edit}) {
			if ($key =~ /^(submit|submission|story|journal)$/) {
				$r->uri('/edit.pl');
				my $type;
				if ($key ne 'submit') {
					$type = $key;
				}
				$r->uri('/edit.pl');
				my %args = $r->args();
				$args{type} = $type if $type;
				my @add_args;

				foreach (qw(url title type bare new introtext)) {
					push @add_args, "$_=". strip_paramattr($args{$_}) if defined $args{$_};
				}
				$r->args(join('&',@add_args)) if @add_args;
				return OK;
			}
		}

		my $new_skin = $slashdb->getSkin($key);
		my $new_skid = $new_skin->{skid} || $constants->{mainpage_skid};
#print STDERR scalar(localtime) . " $$ IndexHandler B new_skid=$new_skid\n";
		setCurrentSkin($new_skid);
		$gSkin = getCurrentSkin();

		my $index_handler = $gSkin->{index_handler};
		if ($index_handler ne 'IGNORE') {
			my $basedir = $constants->{basedir};

			# $USER_MATCH defined above
			if ($dbon && ($is_user || $has_daypass)) {
				$r->args("section=$key");
				# For any directory which can be accessed by a
				# logged-in user in the URI form /foo or /foo/,
				# but which is not a skin's directory, there
				# is a problem;  we cannot simply bounce the uri
				# back to /index.pl or whatever, since the
				# index handler will not recognize the section
				# key argument above and will just present the
				# ordinary homepage.  I don't know the best way
				# to handle this situation at the moment, so
				# instead I'm hardcoding in the solution for the
				# most common problem. - Jamie 2004/07/17
				if ($key eq "faq" || $key eq "palm") {
					$r->uri("/$key/index.shtml");
				} elsif ($key eq "docs"
					|| $key eq "privaterss") {
					$r->uri("/$key/");
				} else {
					$r->uri("/$index_handler");
				}
				$r->filename("$basedir/$index_handler");
				return OK;
			} else {
				# user not logged in

				# consider using File::Basename::basename() here
				# for more robustness, if it ever matters -- pudge
				my($base) = split(/\./, $index_handler);
				$base = 'index' if $base eq 'index2';
				$r->uri("/$key/$base.shtml");
				$r->filename("$basedir/$key/$base.shtml");
				writeLog('shtml');
				return OK;
			}
		}
	}
	if ($uri =~ m#^/(stories|recent|popular|daddypants|search)/([^/]*)/?([^/]*)?/?$#) {
		my ($key, $rss_or_search, $search) = ($1,$2,$3);
		my $rss;	
		if (!$dbon) {
			$r->uri('/index.shtml');
			return DECLINED;
		}
		$rss = 1 if $rss_or_search && $rss_or_search eq "rss";
		$search = $rss_or_search if !$rss;
		
		if ($constants->{plugin}{FireHose}) {
			my $fh_reader = getObject("Slash::FireHose", { db_type => 'reader'});
			my $fh_tabs = $fh_reader->getShortcutUserViews();

			if ($fh_tabs->{$key}) {
		
				my @ops;
				push @ops, "view=$key";
				push @ops, "op=rss", "content_type=rss" if $rss;
				push @ops, "fhfilter=$search", "content_type=rss" if $search;

				$r->args(join('&',@ops));
				if ($rss) {
					$r->uri('/firehose.pl');
				} else {
					$r->uri('/index2.pl');
				}
				return OK;
			}
		}
	}
	
	# Match /datatype/id /story/sid or datatype/id/Item-title syntax
	if ($uri =~ /^\/(journal|submission|comment|story)\/(rss\/)?(\d+(?:\/\d+\/\d+\/\d+)?)\/?(\w+|\-)*\/?/) {
		my $basedir  = $constants->{basedir};
		my($datatype, $rss, $id) = ($1,$2,$3);
		my ($op_string, $rss_string) = ('op=view','');
		if ($rss) {
			$rss_string = "\&content_type=rss";
			$op_string = "op=rss";
		}
		if ($datatype && $id) {
			my $idtype = "id";
			if ($datatype eq "story" && $id =~/\//) {
				$idtype = "sid";
			} 

			$r->filename("$basedir/firehose.pl");
			$r->uri("/firehose.pl");
			$r->args("$op_string\&type=$datatype\&$idtype=$id$rss_string");
			return OK;
		}
	}

	if ($uri eq '/authors.pl') {
		my $filename = $r->filename;
		my $basedir  = $constants->{basedir};

		if (!$dbon || !$is_user) {
			$r->uri('/authors.shtml');
			$r->filename("$basedir/authors.shtml");
			writeLog('shtml');
			return OK;
		}
	}

	if ($uri eq '/hof.pl') {
		my $basedir  = $constants->{basedir};

		$r->uri('/hof.shtml');
		$r->filename("$basedir/hof.shtml");
		writeLog('shtml');
		return OK;
	}

	# Moved, 2009-05
	if ($uri eq '/code.shtml') {
		redirect('/faq/code.shtml', 301);
		return DONE;
	} elsif ($uri eq '/slashdottit.shtml') {
		redirect('/faq/badges.shtml', 301);
		return DONE;
	} elsif ($uri eq '/book.review.guidelines.shtml') {
                redirect('/faq/bookreviews.shtml', 301);
                return DONE;
        }

	# These files are long-outdated and were removed, 2009-05
	if ($uri =~ m{^/
		(   authorguidelines | fool | rules | slashdot_techsay
		  | slashguide | techjobs | anniversary_contest_rules
		)\.shtml
	}x) {
		redirect('/faq/', 301);
		return DONE;
	}

	# redirect to static if
	# * not a user, nor a daypass holder,
	# and
	# * var is on
	# * is article.pl
	# * no page number > 1 specified
	# * sid specified
	# * referrer exists AND is external to our site
	if ($constants->{referrer_external_static_redirect}
		&& !$is_user && !$has_daypass
		&& $uri eq '/article.pl') {
		my $referrer = $r->header_in("Referer");
		my $referrer_domain = $constants->{referrer_domain} || $gSkin->{basedomain};
		my $the_request = $r->the_request;
		if ($referrer
			&& $referrer !~ m{^(?:https?:)?(?://)?(?:[\w-.]+\.)?$referrer_domain(?:/|$)}
			&& $the_request !~ m{\bpagenum=(?:[2-9]|\d\d+)\b}
			&& $the_request =~ m{\bsid=([\d/]+)}
		) {
			my $sid = $1;
			my $slashdb = getCurrentDB();
			my $section = $slashdb->getStory($sid, 'section') || $constants->{defaultsection};

			my $newurl = "/$section/$sid.shtml";
			if (-e "$constants->{basedir}$newurl") {
				redirect($newurl);
				return DONE;
			}
		}
	}

	if (!$dbon && $uri !~ /\.(?:shtml|html|jpg|gif|png|rss|rdf|xml|txt|css)$/) {
		# if db is off we don't necessarily have access to constants
		# this means we change the URI and return DECLINED which lets
		# Apache do the URI to filename translation
		$r->uri('/index.shtml');
		writeLog('shtml');
		$r->notes('SLASH_FAILURE' => "db"); # You should be able to find this in other processes
	}

	return DECLINED;
}

sub DESTROY { }


1;

__END__

=head1 NAME

Slash::Apache - Apache Specific handler for Slash

=head1 SYNOPSIS

	use Slash::Apache2;

=head1 DESCRIPTION

This is what creates the SlashVirtualUser command for us
in the httpd.conf file.

=head1 SEE ALSO

Slash(3).

=cut
