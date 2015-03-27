package Slash::Apache2::Shtml;
use ExtUtils::MakeMaker;

#use Apache2::ExtUtils;
#use Apache2::src ();

WriteMakefile(
	'NAME'	=> 'Slash::Apache2::Shtml',
	'VERSION_FROM' => 'Shtml.pm',
#	'INC'       => Apache2::src->new->inc,
);
