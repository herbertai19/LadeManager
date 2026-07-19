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

sub LMLog
{
    my ($text) = @_;

    my $ts = TimeNow();

    Log3 undef, 1, "[LM] $text";

    if (open(my $fh, ">>", "/opt/fhem/log/LadeManager.log"))
    {
        print $fh "$ts $text\n";
        close($fh);
    }
}

############################################################
# Fahrzeugdaten
############################################################
############################################################
# Konfiguration
############################################################

my %Config = (

    PV_Start         => -100,    # W Einspeisung
    PV_Stop          => 300,     # W Netzbezug

    PV_StartDelay    => 30,      # Sekunden
    PV_StopDelay     => 30,
PV_MinBatterySOC    => 30,    # Unterhalb keine PV-Ladung
PV_ResumeBatterySOC => 35,    # Erst ab diesem SOC wieder freigeben
ChargeEfficiency    => 0.90,
    PV_MinRun => 600,   # 10 Minuten
    Debug         => 0,
);
############################################################
# PV-Hysterese
############################################################

my $PV_StartSince = 0;
my $PV_StopSince  = 0;
my $BatteryLock = 0;
my %AlreadyChargingLogged;
my $NoPVLogged = 0;
my $StartDelayLogged = 0;
my $StopDelayLogged = 0;
my $BatteryLockLogged = 0;

my %Cars = (
Smart => {
    Akku      => 17.0,
    Leistung  => 2.3,
    Shelly    => "Shelly1_Smart",
    Priority  => 1,
    PVReading => "Smart_PV",
    Akku_kWh => 17.6,
},
Ioniq5 => {
    Akku      => 77.4,
    Leistung  => 3.7,
    Shelly    => "Shelly2_Ioniq5",
    Priority  => 2,
    PVReading => "Ioniq_PV",
    Akku_kWh => 77.4,
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
DbgLog("$car: PV=" . IsPVEnabled($car)
    . " Aktiv=" . ReadingsVal("LadeManager","${car}_Aktiv","?")
    . " NeedsCharge=" . NeedsCharge($car));
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

    return (ReadingsVal($shelly,"relay","off") eq "on");
}

############################################################
# StartCar
############################################################

sub StartCar
{
    my ($car,$soc,$ziel) = @_;

    return if(!defined($Cars{$car}));
     my $akkuSOC = ReadingsNum("SENEC","AKKU-Beladung",0);

    if($akkuSOC < $Config{PV_MinBatterySOC})
    {
        LMLog("StartCar: $car verhindert - Speicher ${akkuSOC}%");
        return;
    }
    my $akku     = $Cars{$car}{Akku};
    my $leistung = $Cars{$car}{Leistung};
    my $shelly   = $Cars{$car}{Shelly};

    my ($rest,$netz,$sek,$zeit,$ende) =
        CalcCharge($akku,$leistung,$soc,$ziel);

if($sek == 0)
{
if ($Config{Debug}) {
    LMLog("LadeManager: $car bereits auf Ziel.");
}

    if (IsCharging($car))
    {
    if ($Config{Debug}) {
        LMLog("LadeManager: Stoppe $car (Ziel erreicht)");
        }
        StopCar($car);
    }

    fhem("setreading LadeManager ${car}_Aktiv off");
    fhem("setreading LadeManager ${car}_Status Fertig");
    fhem("setreading LadeManager ${car}_State ${soc}%->$ziel% (fertig)");

    delete $AlreadyChargingLogged{$car};

    return;
}

    my $power = ReadingsNum($shelly,"power",0);

if($power > 100)
{
    unless ($AlreadyChargingLogged{$car})
    {
        LMLog(sprintf(
            "LadeManager: %s laedt bereits (%.0fW).",
            $car,
            $power
        ));
        $AlreadyChargingLogged{$car} = 1;
    }

    return;
}

#-----------------------------------------
# Startwerte für SOC-Schätzung merken
#-----------------------------------------

my $energy = ReadingsNum($shelly,"energy",0);

fhem("setreading LadeManager ${car}_StartSOC $soc");
fhem("setreading LadeManager ${car}_StartEnergy $energy");

LMLog(sprintf(
    "%s: StartSOC=%.1f%% StartEnergy=%.3f",
    $car,
    $soc,
    $energy
));

    fhem("setreading LadeManager ${car}_SOC $soc");
    fhem("setreading LadeManager ${car}_Ziel $ziel");
    fhem("setreading LadeManager ${car}_Rest_kWh $rest");
    fhem("setreading LadeManager ${car}_Netz_kWh $netz");
    fhem("setreading LadeManager ${car}_Ladezeit $zeit");
    fhem("setreading LadeManager ${car}_Ende $ende");
    fhem("setreading LadeManager ${car}_Status Laedt");
    SetCarState($car,"🟠 Lädt (Manuell)");
    # Betriebsmodus merken
    fhem("setreading LadeManager ${car}_Modus Manuell");
    fhem("setreading LadeManager ${car}_State $soc%->$ziel% ($zeit)");
if ($Config{Debug}) {
    LMLog("LadeManager: $car startet fuer $zeit");
}
    fhem("set $shelly on-for-timer $sek");
    fhem("setreading LadeManager ${car}_StartTime " . time());
}

############################################################
# StopCar
############################################################

sub StopCar
{
    my ($car)=@_;

    my $shelly = $Cars{$car}{Shelly};

    return if(ReadingsVal($shelly,"relay","off") eq "off");

#-----------------------------------------
# Aktuellen SOC als neuen Startwert sichern
#-----------------------------------------

my $soc = ReadingsNum("LadeManager","${car}_SOC",0);
my $energy = ReadingsNum($shelly,"energy",0);

fhem("setreading LadeManager ${car}_StartSOC $soc");
fhem("setreading LadeManager ${car}_StartEnergy $energy");

LMLog(sprintf(
    "%s: Neuer StartSOC=%.1f%% StartEnergy=%.3f",
    $car,
    $soc,
    $energy
));

    fhem("set $shelly off");
    fhem("setreading LadeManager ${car}_Modus -");

if (NeedsCharge($car))
{
      SetCarState($car,"🟡 Wartet auf PV");
}
else
{
    fhem("setreading LadeManager ${car}_Status Fertig");
    SetCarState($car,"⚪ Fertig");
    fhem("setreading LadeManager ${car}_Aktiv off");
    if ($Config{Debug}) {
    LMLog("$car fertig -> pruefe naechstes PV-Fahrzeug");
    }
}
delete $AlreadyChargingLogged{$car};
    LMLog("StopCar: $car gestoppt");
    fhem("deletereading LadeManager ${car}_StartTime");
}

############################################################
# CheckStart
############################################################

sub CheckStart
{
    my ($car,$netz,$soc,$ziel)=@_;

    if($netz <= $Config{PV_Start})
    {
        if(!$PV_StartSince)
        {
            $PV_StartSince = time();
LMLog(sprintf(
    "CheckPV: Start-Timer gestartet (Netz=%.0fW)",
    $netz,
));
            return;
        }

if(time() - $PV_StartSince < $Config{PV_StartDelay})
{
    my $rest = $Config{PV_StartDelay} - (time() - $PV_StartSince);
    $rest = 0 if $rest < 0;

    my $min = int($rest / 60);
    my $sec = $rest % 60;

    unless ($StartDelayLogged)
    {
        LMLog(sprintf(
            "CheckPV: Startverzögerung (%02d:%02d verbleibend)",
            $min,
            $sec
        ));
        $StartDelayLogged = 1;
    }

    return;
}

$StartDelayLogged = 0;
if ($Config{Debug}) {
        LMLog("CheckPV: Starte $car");
}
StartPV($car,$soc,$ziel);

        $PV_StartSince = 0;
        $StartDelayLogged = 0;
    }
    else
    {
        if($PV_StartSince)
        {
   LMLog(sprintf(
    "CheckPV: Start-Timer verworfen (Netz=%.0fW)",
    $netz,
));
        }

        $PV_StartSince = 0;
        $StartDelayLogged = 0;
    }
}

############################################################
# Komfortfunktionen Smart
############################################################

sub Smart85
{
    my $soc = ReadingsNum("LadeManager","Smart_SOC",50);

    fhem("setreading LadeManager Smart_Aktiv on");
    fhem("setreading LadeManager Smart_Ziel 85");

    if(IsPVEnabled("Smart"))
    {
    if ($Config{Debug}) {
        LMLog("Smart85: PV-Modus");
        }
        CheckPV();
    }
    else
    {

    if ($Config{Debug}) {
        LMLog("Smart85: Sofort laden");
        }
        StartCar("Smart",$soc,85);
    }
}

sub Smart100
{
    my $soc = ReadingsNum("LadeManager","Smart_SOC",50);

    fhem("setreading LadeManager Smart_Aktiv on");
    fhem("setreading LadeManager Smart_Ziel 100");

    if(IsPVEnabled("Smart"))
    {
    if ($Config{Debug}) {
        LMLog("Smart100: PV-Modus");
        }
        CheckPV();
    }
    else
    {
    if ($Config{Debug}) {
        LMLog("Smart100: Sofort laden");
        }
        StartCar("Smart",$soc,100);
    }
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

my $netz  = GetNetPower();
my $pvcar = GetNextPVCar();
my $akku  = ReadingsNum("SENEC","AKKU-Beladung",0);

my $akku = ReadingsNum("SENEC","AKKU-Beladung",0);

UpdateChargeStatus("Smart");
UpdateChargeStatus("Ioniq5");

# Übergang in den Sperrzustand
if(!$BatteryLock && $akku < $Config{PV_MinBatterySOC})
{
    LMLog("CheckPV: Speicher unter $Config{PV_MinBatterySOC}% ($akku%)");

    $BatteryLock = 1;
    $BatteryLockLogged = 0;

    StopChargingCars();
    return;
}

# Bereits gesperrt
if($BatteryLock)
{
    if($akku >= $Config{PV_ResumeBatterySOC})
    {
        LMLog("CheckPV: Speicher wieder freigegeben ($akku%)");
        $BatteryLock = 0;
        $BatteryLockLogged = 0;
    }
    else
    {
        unless($BatteryLockLogged)
        {
            LMLog("CheckPV: Speicher gesperrt ($akku%)");
            $BatteryLockLogged = 1;
        }

        StopChargingCars();
        return;
    }
}

unless (defined $pvcar)
{
    $PV_StartSince = 0;
    $PV_StopSince  = 0;

    unless ($NoPVLogged)
    {
    if ($Config{Debug}) {
        LMLog("CheckPV: Kein PV-Fahrzeug");
        }
        $NoPVLogged = 1;
    }

    return;
}

$NoPVLogged = 0;

my $car = $pvcar;

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
  
if (!IsCharging($car))
{
    CheckStart($car,$netz,$soc,$ziel);
}
else
{
    $PV_StartSince = 0;
}

if($netz >= $Config{PV_Stop})
{
    $PV_StartSince = 0;

return unless IsCharging($car);

my $start = ReadingsNum("LadeManager","${car}_StartTime",0);

if ($start && (time() - $start) < $Config{PV_MinRun})
{
    my $rest = $Config{PV_MinRun} - (time() - $start);
    $rest = 0 if $rest < 0;

    my $min = int($rest / 60);
    my $sec = $rest % 60;

    LMLog(sprintf(
        "CheckPV: Mindestlaufzeit aktiv (%02d:%02d verbleibend)",
        $min,
        $sec
    ));
    SetCarState($car,"🔵 Mindestlaufzeit");

    return;
}

    if(!$PV_StopSince)
    {
        $PV_StopSince = time();
        
LMLog(sprintf(
    "CheckPV: Stop-Timer gestartet (Netz=%.0fW)",
    $netz,
));
        return;
    }

if(time() - $PV_StopSince < $Config{PV_StopDelay})
{
    my $rest = $Config{PV_StopDelay} - (time() - $PV_StopSince);
    $rest = 0 if $rest < 0;

    my $min = int($rest / 60);
    my $sec = $rest % 60;

    unless ($StopDelayLogged)
    {
        LMLog(sprintf(
            "CheckPV: Stopverzögerung (%02d:%02d verbleibend)",
            $min,
            $sec
        ));
        $StopDelayLogged = 1;
    }

    return;
}

$StopDelayLogged = 0;

    LMLog("CheckPV: Stoppe $car");
    StopPV($car);

    $PV_StopSince = 0;
    $StopDelayLogged = 0;
}
else
{
    if($PV_StopSince)
    {
LMLog(sprintf(
    "CheckPV: Stop-Timer verworfen (Netz=%.0fW)",
    $netz
));
    }

    $PV_StopSince = 0;
    $StopDelayLogged = 0;
}
}

############################################################
# Start PV-Ladung
############################################################

sub StartPV
{
    my ($car,$soc,$ziel) = @_;

    LMLog("StartPV: $car");

    StartCar($car,$soc,$ziel);
    SetCarState($car,"🟢 Lädt (PV)");
}

############################################################
# Stop PV-Ladung
############################################################

sub StopPV
{
    my ($car) = @_;

    LMLog("StopPV: $car");

    StopCar($car);
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

sub DbgLog
{
    my ($text) = @_;

    return unless $Config{Debug};

    LMLog($text);
}

sub StopChargingCars
{
    StopPV("Smart")  if IsCharging("Smart");
    StopPV("Ioniq5") if IsCharging("Ioniq5");
}

sub UpdateChargeStatus
{
    my ($car) = @_;

    return unless(IsCharging($car));

    my $shelly = $Cars{$car}{Shelly};

    my $startSOC    = ReadingsNum("LadeManager","${car}_StartSOC",0);
    my $startEnergy = ReadingsNum("LadeManager","${car}_StartEnergy",0);

    my $energy = ReadingsNum($shelly,"energy",0);

    # Akkugröße gleich am Anfang holen
    my $akku = $Cars{$car}{Akku_kWh};

    return if($energy <= $startEnergy);

my $geladen = ($energy - $startEnergy) / 1000;
    
    LMLog(sprintf(
    "%s: StartEnergy=%.3f  Energy=%.3f  Geladen=%.3f",
    $car,
    $startEnergy,
    $energy,
    $geladen
));

    if($geladen < -0.01)
    {
        LMLog("$car: Shelly-Energiezähler zurückgesetzt.");
        fhem("setreading LadeManager ${car}_StartEnergy $energy");
        return;
    }

    if($geladen > $akku * 1.2)
    {
        LMLog("$car: unrealistische Energiemenge ($geladen kWh)");
        return;
    }

    my $soc = $startSOC
            + ($geladen * $Config{ChargeEfficiency} / $akku * 100);

    my $ziel = ReadingsNum("LadeManager","${car}_Ziel",100);

    $soc = $ziel if($soc > $ziel);

    fhem(sprintf(
        "setreading LadeManager %s_SOC %.1f",
        $car,
        $soc
    ));

    # Aktuelle Ladeleistung vom Shelly
    my $power = ReadingsNum($shelly,"power",0) / 1000;

    # Falls der Shelly gerade Unsinn liefert
    if($power < 0.5)
    {
        $power = $Cars{$car}{Leistung};
    }

    fhem(sprintf(
        "setreading LadeManager %s_Leistung %.2f",
        $car,
        $power
    ));

    my ($rest,$netz,$sek,$zeit,$ende) =
        CalcCharge(
            $akku,
            $power,
            $soc,
            $ziel
        );

    fhem("setreading LadeManager ${car}_Rest_kWh $rest");
    fhem("setreading LadeManager ${car}_Netz_kWh $netz");
    fhem("setreading LadeManager ${car}_Ladezeit $zeit");
    fhem("setreading LadeManager ${car}_Ende $ende");

my $state = ReadingsVal(
    "LadeManager",
    "${car}_State",
    "-"
);

my $status = sprintf(
    "%s | %.1f%% | %.2f kWh geladen | %.2f kWh Rest | %.2f kW | Ende %s",
    $state,
    $soc,
    $geladen,
    $rest,
    $power,
    $ende
);

    fhem("setreading LadeManager ${car}_Info $status");
}

sub SetCarState
{
    my ($car,$state) = @_;

    fhem("setreading LadeManager ${car}_State $state");

    LMLog("$car: Status -> $state");
}

1;
