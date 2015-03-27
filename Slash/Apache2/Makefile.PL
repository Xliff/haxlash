package Slash::Apache2;

use ExtUtils::MakeMaker;

#Kinda weird looking ain't it? -Brian

WriteMakefile(
    'NAME'	=> 'Slash::Apache2',
    'VERSION_FROM' => 'Apache2.pm',
#    'INC'	=> Apache2::src->new->inc, 
);
