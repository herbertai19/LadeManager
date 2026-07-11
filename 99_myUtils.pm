package main;

use strict;
use warnings;
use POSIX qw(strftime);

#########################################
# myUtils
#########################################

sub myUtils_Initialize() {
    return;
}

############################################################
# Fahrzeugdaten
############################################################

my %Cars = (

    Smart => {
        Akku    => 17.0,
        Leistung=> 2.3,
        Shelly  => "Shelly1_Smart",
    },

    Ioniq5 => {
        Akku    => 77.4,
        Leistung=> 3.7,
        Shelly  => "Shelly2_Ioniq5",
    }

);
############################################################
# CalcCharge
#
# Parameter:
#   Akku_kWh
#   Ladeleistung_kW
#   SOC_aktuell
#   SOC_Ziel
#
# Rueckgabe:
#   Rest_kWh
#   Netz_kWh
#   Ladezeit_Sekunden
#   Ladezeit_Text
#   Ende_Text
############################################################

sub CalcCharge
{
    my ($akku,$leistung,$soc,$ziel) = @_;

    my $wirkungsgrad = 0.92;

    return (0,0,0,"00:00","-")
        if($soc >= $ziel);

    my $restProzent = $ziel - $soc;

    my $restkWh = $akku * $restProzent / 100.0;

    my $netzkWh = $restkWh / $wirkungsgrad;

    my $stunden = $netzkWh / $leistung;

    my $sekunden = int($stunden * 3600);

    my $hh = int($sekunden / 3600);
    my $mm = int(($sekunden % 3600) / 60);

    my $ladezeit = sprintf("%02d:%02d",$hh,$mm);

    my $ende = strftime(
        "%d.%m.%Y %H:%M",
        localtime(time()+$sekunden)
    );

    return(
        sprintf("%.2f",$restkWh),
        sprintf("%.2f",$netzkWh),
        $sekunden,
        $ladezeit,
        $ende
    );
}
############################################################
# StartCar
############################################################

sub StartCar
{
    my ($car,$soc,$ziel) = @_;
    Log 1, "DEBUG StartCar: car=$car soc=$soc ziel=$ziel";

    return if(!defined($Cars{$car}));

    my $akku     = $Cars{$car}{Akku};
    my $leistung = $Cars{$car}{Leistung};
    my $shelly   = $Cars{$car}{Shelly};

    my ($rest,$netz,$sek,$zeit,$ende) =
        CalcCharge($akku,$leistung,$soc,$ziel);

    if($sek == 0)
    {
        Log 1,"LadeManager: $car bereits auf Ziel.";
        return;
    }



    fhem("setreading LadeManager ${car}_SOC $soc");
    fhem("setreading LadeManager ${car}_Ziel $ziel");
    fhem("setreading LadeManager ${car}_Rest_kWh $rest");
    fhem("setreading LadeManager ${car}_Netz_kWh $netz");
    fhem("setreading LadeManager ${car}_Ladezeit $zeit");
    fhem("setreading LadeManager ${car}_Ende \"$ende\"");

    fhem("setreading LadeManager ${car}_Status Laedt");
    fhem("setreading LadeManager ${car}_State $soc%->$ziel% ($zeit)");
    my $power = ReadingsNum($shelly,"power",0);

    if($power > 100)
    {
        Log 1,"LadeManager: $car laedt bereits (${power}W).";
        return;
    }
    Log 1,"LadeManager: $car startet fuer $zeit";

    fhem("set $shelly on-for-timer $sek");
}
sub StartSmart
{
    my ($soc,$ziel)=@_;

    StartCar("Smart",$soc,$ziel);
}
sub StartIoniq
{
    my ($soc,$ziel)=@_;

    StartCar("Ioniq5",$soc,$ziel);
}
############################################################
# Komfortfunktionen Smart
############################################################

sub Smart85
{
    my $soc = ReadingsNum("LadeManager","Smart_SOC",50);

    StartCar("Smart",$soc,85);
}

sub Smart100
{
    my $soc = ReadingsNum("LadeManager","Smart_SOC",50);

    StartCar("Smart",$soc,100);
}

###############################################
# Smart SOC +5
###############################################
sub SmartPlus {

    my $soc = ReadingsNum("LadeManager","Smart_SOC",50);

    $soc += 5;

    $soc = 100 if($soc > 100);

    readingsSingleUpdate($defs{"LadeManager"}, "Smart_SOC", $soc, 1);

}

###############################################
# Smart SOC -5
###############################################
sub SmartMinus {

    my $soc = ReadingsNum("LadeManager","Smart_SOC",50);

    $soc -= 5;

    $soc = 0 if($soc < 0);

    readingsSingleUpdate($defs{"LadeManager"}, "Smart_SOC", $soc, 1);

}

############################################################
# Komfortfunktionen Ioniq5
############################################################

sub Ioniq85
{
    my $soc = ReadingsNum("LadeManager","Ioniq5_SOC",50);

    StartCar("Ioniq5",$soc,85);
}

sub Ioniq100
{
    my $soc = ReadingsNum("LadeManager","Ioniq5_SOC",50);

    StartCar("Ioniq5",$soc,100);
}

###############################################
# Ioniq SOC +5
###############################################
sub IoniqPlus {

    my $soc = ReadingsNum("LadeManager","Ioniq5_SOC",50);

    $soc += 5;

    $soc = 100 if($soc > 100);

    readingsSingleUpdate($defs{"LadeManager"}, "Ioniq5_SOC", $soc, 1);

}

###############################################
# Ioniq SOC -5
###############################################
sub IoniqMinus {

    my $soc = ReadingsNum("LadeManager","Ioniq5_SOC",50);

    $soc -= 5;

    $soc = 0 if($soc < 0);

    readingsSingleUpdate($defs{"LadeManager"}, "Ioniq5_SOC", $soc, 1);

}
############################################################
# SetSOC
############################################################

sub SetSOC
{
    my ($car,$soc)=@_;

    return if(!defined($Cars{$car}));

    $soc = int($soc);

    $soc = 0   if($soc < 0);
    $soc = 100 if($soc > 100);

    readingsSingleUpdate(
        $defs{"LadeManager"},
        "${car}_SOC",
        $soc,
        1
    );
}
1;
