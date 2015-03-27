use ExtUtils::MakeMaker;

WriteMakefile(
	'NAME'	=> 'Slash::Apache2::User',
	'VERSION_FROM' => 'User.pm',
#	'INC'       => Apache2::src->new->inc,
);
