#!/usr/bin/perl

use Apache2::Module ();

foreach $sym (sort keys %Apache2::Module::) {
	local *lsym = $Apache2::{$$sym};

	print "\$$sym is defined\n" if $lsym;
	print "\@$sym is defined\n" if @lsym;
	print "\%$sym is defined\n" if %lsym;
	print "\&$sum is defined\n" if &lsym;
}
