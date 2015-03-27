# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2005 by Open Source Technology Group. See README
# and COPYING for more information, or see http://slashcode.com/.

# This Apache handler massages existing .shtml files to give them a
# modern (2009) header and footer.

package Slash::Apache2::Shtml;

use strict;

use Apache2;
use Apache2::Const qw(:common);
use Apache2::RequestUtil ();
#use Slash::Apache2 ();
use Slash::Utility;

use vars qw($VERSION @ISA);
@ISA = qw(DynaLoader);
$VERSION = '2.005';

sub handler {
	my($r) = @_;

	return DECLINED unless $r->is_initial_req;

	Apache2::RequestUtil->request($r);
	my $uri = $r->uri;

	# Only .shtml URLs are processed by this handler.
	return DECLINED unless $uri =~ m{\.shtml(\?|$)};

	# And right now, only a few of them.
	return DECLINED unless
		   $uri =~ m{^/faq}
		|| $uri =~ m{^/(hof|about|moderation|cheesyportal|authors|awards|supporters|prettypictures)\.shtml};

	my $constants = getCurrentStatic();
	$r->args("uri=$uri");
	$r->uri('/shtml.pl');
	$r->filename("$constants->{basedir}/shtml.pl");
	return OK;
}

sub DESTROY { }

1;

