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
############################################################
# Konfiguration
############################################################

my %Config = (

    PV_Start         => 300,    # W Einspeisung
    PV_Stop          => 150,     # W Netzbezug

    PV_StartDelay    => 60,      # Sekunden
    PV_StopDelay     => 30,

    PV_CheckInterval => 30,

);
############################################################
# PV-Hysterese
############################################################

my $PV_StartSince = 0;
my $PV_StopSince  = 0;

my %Cars = (
Smart => {
    Akku      => 17.0,
    Leistung  => 2.3,
    Shelly    => "Shelly1_Smart",
    Priority  => 1,
    PVReading => "Smart_PV",
},
Ioniq5 => {
    Akku      => 77.4,
    Leistung  => 3.7,
    Shelly    => "Shelly2_Ioniq5",
    Priority  => 2,
    PVReading => "Ioniq_PV",
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
# Netzleistung lesen
############################################################

sub GetNetPower
{
    return ReadingsNum("SENEC","Netz-Bezug",0);
}

############################################################
# PV-Modus aktiv?
############################################################

sub IsPVEnabled
{
    my ($car) = @_;

    return ReadingsVal(
    "LadeManager",
    $Cars{$car}{PVReading},
    "off"
) eq "on";
}

############################################################
# Ziel noch nicht erreicht?
############################################################

sub NeedsCharge
{
    my ($car) = @_;

    my $aktiv = ReadingsVal(
        "LadeManager",
        "${car}_Aktiv",
        "off"
    );

    return 0 unless ($aktiv eq "on");

    my $soc = ReadingsNum(
        "LadeManager",
        "${car}_SOC",
        0
    );

    my $ziel = ReadingsNum(
        "LadeManager",
        "${car}_Ziel",
        100
    );

    return ($soc < $ziel);
}

############################################################
# Nächstes Fahrzeug für PV-Ladung bestimmen
############################################################

sub GetNextPVCar
{
    foreach my $car (
        sort {
            $Cars{$a}{Priority} <=> $Cars{$b}{Priority}
        } keys %Cars
    )
    {
        next unless IsPVEnabled($car);
        next unless NeedsCharge($car);

        return $car;
    }

    return undef;
}

############################################################
# Fahrzeug angeschlossen?
############################################################

sub IsCharging
{
    my ($car) = @_;

    my $shelly = $Cars{$car}{Shelly};

    return ReadingsNum($shelly,"relay",0);
}

############################################################
# StartCar
############################################################

sub StartCar
{
    my ($car,$soc,$ziel) = @_;

    return if(!defined($Cars{$car}));

    my $akku     = $Cars{$car}{Akku};
    my $leistung = $Cars{$car}{Leistung};
    my $shelly   = $Cars{$car}{Shelly};

    my ($rest,$netz,$sek,$zeit,$ende) =
        CalcCharge($akku,$leistung,$soc,$ziel);

    if($sek == 0)
    {
        Log 1,"LadeManager: $car bereits auf Ziel.";
        fhem("setreading LadeManager ${car}_Aktiv off");
        fhem("setreading LadeManager ${car}_Status Fertig");
        fhem("setreading LadeManager ${car}_State ${ziel}%->$ziel% (fertig)");
        
        return;
    }

    my $power = ReadingsNum($shelly,"power",0);

    if($power > 100)
    {
        Log 1,"LadeManager: $car laedt bereits (${power}W).";
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

    Log 1,"LadeManager: $car startet fuer $zeit";

    fhem("set $shelly on-for-timer $sek");
}

############################################################
# StopCar
############################################################

sub StopCar
{
    my ($car)=@_;

    my $shelly = $Cars{$car}{Shelly};

    return if(ReadingsVal($shelly,"relay","off") eq "off");

    fhem("set $shelly off");

    fhem("setreading LadeManager ${car}_Status WARTET");

    Log 1,"StopCar: $car gestoppt";
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
    fhem("setreading LadeManager Smart_Aktiv on");
    StartCar("Smart",$soc,85);
}

sub Smart100
{
    my $soc = ReadingsNum("LadeManager","Smart_SOC",50);
    fhem("setreading LadeManager Smart_Aktiv on");
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
    fhem("setreading LadeManager Ioniq5_Aktiv on");
    StartCar("Ioniq5",$soc,85);
}

sub Ioniq100
{
    my $soc = ReadingsNum("LadeManager","Ioniq5_SOC",50);
    fhem("setreading LadeManager Ioniq5_Aktiv on");
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
# PV-Ladesteuerung
############################################################

sub CheckPV
{
    Log 1,"*** CheckPV wurde aufgerufen ***";

    my $netz = GetNetPower();

    Log 1,"CheckPV: Netz = $netz W";

    foreach my $car (
        sort {
            $Cars{$a}{Priority} <=> $Cars{$b}{Priority}
        } keys %Cars)
    {
        next unless IsPVEnabled($car);
        next unless NeedsCharge($car);

        my $soc = ReadingsNum(
            "LadeManager",
            "${car}_SOC",
            0
        );

        my $ziel = ReadingsNum(
            "LadeManager",
            "${car}_Ziel",
            100
        );

if($netz <= $Config{PV_Start})
{
    if(!$PV_StartSince)
    {
        $PV_StartSince = time();
        Log 1,"CheckPV: Start-Timer gestartet";
        return;
    }

    if(time() - $PV_StartSince < $Config{PV_StartDelay})
    {
        Log 1,"CheckPV: Warte auf Startverzögerung";
        return;
    }

    Log 1,"CheckPV: Starte $car";
    StartCar($car,$soc,$ziel);

    $PV_StartSince = 0;
}
elsif($netz > $Config{PV_Start} && $netz < $Config{PV_Stop})
{
    if($PV_StartSince)
    {
        Log 1,"CheckPV: Start-Timer verworfen";
    }

    $PV_StartSince = 0;
}
elsif($netz >= $Config{PV_Stop})
{
    $PV_StartSince = 0;

    Log 1,"CheckPV: Stoppe $car";
    StopCar($car);
}

        last;
    }
}

############################################################
# Start PV-Ladung
############################################################

sub StartPV
{
    my ($car) = @_;

    Log 1,"StartPV: $car";
}

############################################################
# Stop PV-Ladung
############################################################

sub StopPV
{
    my ($car) = @_;

    Log 1,"StopPV: $car";
}

sub TestPV
{
    my $soc  = ReadingsNum("LadeManager","Smart_SOC",0);
    my $ziel = ReadingsNum("LadeManager","Smart_Ziel",85);

    StartCar("Smart",$soc,$ziel);
}

sub TestStop
{
    StopCar("Smart");
}
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

    fhem("setreading LadeManager ${car}_Aktiv on");
}
1;
