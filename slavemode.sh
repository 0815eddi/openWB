#!/bin/bash

HeartbeatTimeout=35
CurrentLimitAmpereForCpCharging=0.5
NumberOfSupportedChargePoints=2
LastChargingPhaseFile="ramdisk/lastChargingPhasesLp"
SystemVoltage=240

#
# the main entry point of the script that is called from outside
openwbisslave() {

	# prepare for normal debug output in level 2, in others echo is the null command :
	dbgWrite=:
	if (( debug == 2 )); then
		dbgWrite=echo
	fi

	setVariablesFromRamdisk

	checkControllerHeartbeat

	for ((currentCp=1; currentCp<=NumberOfSupportedChargePoints; currentCp++)); do

		# we have to do a slightly ugly if-else-cascade to determine whether the currentCp is actually present
		# if not we continue the loop with the next CP
		if (( currentCp == 1)); then
			# CP1 exists unconditionally
			:
		elif (( currentCp == 2)) && (( lastmanagement == 0)); then
			# CP2 does not actually exist
			continue
		elif (( currentCp == 3)) && (( lastmanagements2 == 0)); then
			# CP3 does not actually exist
			continue
		elif (( currentCp >= 4)); then
			local cpPresentVar="lastmanagementlp${currentCp}"
			eval cpPresent=\$$cpPresentVar
			if (( cpPresent == 0 )); then

				# CPx (x >= 4) does not actually exist
				continue
			fi
		else
			echo "$NowItIs: Slave Mode charge point ERROR: Charge Point #${currentCp} is not supported"
			continue
		fi

		# handle the currentCp: first aggregate the data ...
		aggregateDataForChargePoint $currentCp

		# ... then calculate the new possible charge current
		computeAndSetCurrentForChargePoint $currentCp

	done

	echo "Slave Mode Aktiv, openWB NUR fernsteuerbar" > ramdisk/lastregelungaktiv

	exit 0
}

# actually computes the new allowed charge current for the given charge point
function computeAndSetCurrentForChargePoint() {

	# the charge point that we're looking at is our first parameter
	local chargePoint=$1

	declare -i chargingVehiclesAdjustedForThisCp=${ChargingVehiclesOnPhase[$ChargingPhaseWithMaximumTotalCurrent]}
	if !(( CpIsCharging )); then

		# add 1 for "ourself" as we need to calculate as if we were actually charging
		chargingVehiclesAdjustedForThisCp=$((chargingVehiclesAdjustedForThisCp+1))
	fi

	if (( chargingVehiclesAdjustedForThisCp == 0 )); then
		# this can happen in transient when master has not yet detected us as charging but we have already detected us as charging and no other car is charging
		$dbgWrite "$NowItIs: Slave Mode: chargingVehiclesAdjustedForThisCp == 0 - forcing chargingVehiclesAdjustedForThisCp=1 for CP#${chargePoint}"
		chargingVehiclesAdjustedForThisCp=1
	fi

	# compute difference between allowed current on the total current of the phase that has the highest total current and is actually used for charging
	# in floats for not to loose too much precision
	lldiff=$(echo "scale=3; ($AllowedTotalCurrentPerPhase - ${TotalCurrentOfChargingPhaseWithMaximumTotalCurrent}) / ${chargingVehiclesAdjustedForThisCp}" | bc)

	# see if we have to limit by allowed peak power (we have to if the value exists in ramdisk file and is > 0, ==0 means: peak limit disabled)
	if (( `echo "$AllowedPeakPower > 0" | bc` == 1 )); then

		if (( TotalPowerConsumption == -1 )); then
			echo "$NowItIs: Slave Mode: ERROR: Peak power limit set (${AllowedPeakPower} W) but total power consumption not availble (TotalPowerConsumption=${TotalPowerConsumption} W): Immediately stopping charge and exiting"
			callSetCurrent 0 $chargePoint
			exit 2
		fi

		local pwrDiff=$(echo "scale=3; ($AllowedPeakPower - ${TotalPowerConsumption}) / ${chargingVehiclesAdjustedForThisCp}" | bc)
		local pwrCurrDiff=$(echo "scale=3; (${pwrDiff} / ${SystemVoltage} / ${NumberOfChargingPhases})" | bc)

		if (( `echo "$pwrCurrDiff < $lldiff" | bc` == 1 )); then
			$dbgWrite "$NowItIs: Slave Mode: Difference to power limt of $AllowedPeakPower W is $pwrDiff W (@ ${SystemVoltage} V @ ${chargingVehiclesAdjustedForThisCp} charging vehicles) --> overriding $lldiff A to $pwrCurrDiff A on ${NumberOfChargingPhases} phase(s)"
			lldiff=$pwrCurrDiff
		fi
	fi

	# new charge current in int but always rounded to the next _lower_ integer
	llneu=$(echo "scale=0; ($llalt + $lldiff)/1" | bc)

	$dbgWrite "$NowItIs: Slave Mode: AllowedTotalCurrentPerPhase=$AllowedTotalCurrentPerPhase A, AllowedPeakPower=${AllowedPeakPower} W, TotalPowerConsumption=${TotalPowerConsumption} W"
    $dbgWrite "$NowItIs: Slave Mode: TotalCurrentOfChargingPhaseWithMaximumTotalCurrent=${TotalCurrentOfChargingPhaseWithMaximumTotalCurrent} A, chargingVehiclesAdjustedForThisCp=${chargingVehiclesAdjustedForThisCp}, llalt=$llalt A, lldiff=$lldiff A"

	# limit the change to +1, -1 or -3 if slow ramping is enabled,
	# a value of 0 will be kept unchanged
	if (( slaveModeSlowRamping == 1 )); then

		local adjustment=0;
		if (( `echo "$lldiff > 1" | bc` == 1 )); then
			adjustment=1
		elif (( `echo "$lldiff < -3" | bc` == 1 )); then
			adjustment=-3
		elif (( `echo "$lldiff < 0" | bc` == 1 )); then
			adjustment=-1
		fi

		if !(( CpIsCharging )); then
			# if we're not charging, we always start off with minimalstromstaerke
		if (( `echo "$lldiff < 0" | bc` == 1 )); then
				llneu=0

				$dbgWrite "$NowItIs: Slave Mode: Slow ramping: Not charging: Too few current left to start"
			else
				llneu=${minimalstromstaerke}

				$dbgWrite "$NowItIs: Slave Mode: Slow ramping: Not charging: Starting at minimal supported charge current ${llneu} A"
			fi
		else
			llneu=$(( llalt + adjustment ))
			$dbgWrite "$NowItIs: Slave Mode: Slow ramping: Limiting adjustment to ${llalt} + (${adjustment}) --> llneu = ${llneu} A"
		fi
	else

		# In "fast" mode the llneu might exceed the AllowedTotalCurrentPerPhase if the EV doesn't actually start consuming
		# the allowed current (and hence TotalCurrentConsumptionOnL1 doesn't increase).
		# For this case we limit to the total allowed current divided by the number of charging vehicals.
		# The resulting value might get further limited to maximalstromstaerke below.
		if (( `echo "$llneu > $AllowedTotalCurrentPerPhase" | bc` == 1 )); then

			$dbgWrite "$NowItIs: Slave Mode: Fast ramping: Special case: EV consuming less than allowed. Limiting to AllowedTotalCurrentPerPhase/ChargingVehicles"

			llneu=$(echo "scale=0; ($AllowedTotalCurrentPerPhase/${chargingVehiclesAdjustedForThisCp})" | bc)
		else
			$dbgWrite "$NowItIs: Slave Mode: Fast ramping: Setting llneu=$llneu A"
		fi
	fi

	# finally limit to the configured min or max values
	if (( llneu < minimalstromstaerke )) || ((LpEnabled == 0)); then
		if ((LpEnabled != 0)); then
			$dbgWrite "$NowItIs: Slave Mode Aktiv, LP akt., LpEnabled=$LpEnabled, llneu=$llneu < minmalstromstaerke=$minimalstromstaerke --> setze llneu=0"
		else
			$dbgWrite "$NowItIs: Slave Mode Aktiv, LP deakt. --> setze llneu=0"
		fi
		llneu=0
	fi
	if (( llneu > maximalstromstaerke )); then
		$dbgWrite "$NowItIs: Slave Mode Aktiv, llneu=$llneu < maximalstromstaerke=$maximalstromstaerke --> setze llneu=$maximalstromstaerke"
		llneu=$maximalstromstaerke
	fi

	callSetCurrent $llneu $chargePoint

	if (( llalt != llneu )); then
		echo "$date Ändere Ladeleistung von $llalt auf $llneu Ampere" >> ramdisk/ladestatus.log
	fi

	return 0
}


# determines the relevant phase for comparision against allowed current
# if we're charging on n phases we use the one with the highest total current reported by controller
# if we're not charging at all, we assume that we would start charging an 3 phases and thus use the
# highest of the total currents reported by controller
function aggregateDataForChargePoint() {

	# the charge point that we're looking at is our first parameter
	local chargePoint=$1

	# the per-phase currents (4 elements as index 0 will be ignored)
	ChargeCurrentOnPhase=(0 0 0 0)

	# the per-phase charge indicator (0 = not charging, 1 = charging)
	ChargingOnPhase=(0 0 0 0)

	# value indicating whether this CP is actually charging
	CpIsCharging=0

	ChargingPhaseWithMaximumTotalCurrent=0
	TotalCurrentOfChargingPhaseWithMaximumTotalCurrent=0

	# indication whether the given charge point is actually enabled
	local cpenabledVar="lp${chargePoint}enabled"
	eval LpEnabled=\$$cpenabledVar

	# iterate the phases (index 1-3, index 0 of array will simply be untouched/ignored)
	NumberOfChargingPhases=0
	for i in {1..3}; do

		# we have to do a slightly ugly if-else-cascade to determine the right ramdisk file name
		if (( chargePoint == 1 )); then
			ChargeCurrentOnPhase[i]=$(<"ramdisk/lla${i}")
		elif (( chargePoint == 2 )); then
			ChargeCurrentOnPhase[i]=$(<"ramdisk/llas1${i}")
		elif (( chargePoint == 3 )); then
			ChargeCurrentOnPhase[i]=$(<"ramdisk/llas2${i}")
		elif (( chargePoint >= 4 )); then
			ChargeCurrentOnPhase[i]=$(<"ramdisk/lla${i}lp${chargePoint}")
		else
			echo "$NowItIs: Slave Mode charge current fetch ERROR: Charge Point #${chargePoint} is not supported"
			return 1
		fi

		# detect the phases on which WE are CURRENTLY charging
		if (( `echo "${ChargeCurrentOnPhase[i]} > $CurrentLimitAmpereForCpCharging" | bc` == 1 )); then
			ChargingOnPhase[i]=1
			CpIsCharging=1
			NumberOfChargingPhases=$(( NumberOfChargingPhases + 1 ))

			if (( `echo "${TotalCurrentConsumptionOnPhase[i]} > $TotalCurrentOfChargingPhaseWithMaximumTotalCurrent" | bc` == 1 )); then
				TotalCurrentOfChargingPhaseWithMaximumTotalCurrent=${TotalCurrentConsumptionOnPhase[i]}
				ChargingPhaseWithMaximumTotalCurrent=$i
			fi
		fi
	done

	# write the phases on which we're currently charging to the ramdisk
	if (( CpIsCharging == 1 )); then
		local chargingOnPhaseString="${ChargingOnPhase[*]}"
		echo "${chargingOnPhaseString//${IFS:0:1}/,}" > "${LastChargingPhaseFile}${chargePoint}"
	fi

	# if we're not charging at all, try smart fallback first: uses the phase(s) on which we have last charged or
	if (( ChargingPhaseWithMaximumTotalCurrent == 0 )); then

		# check if "last charging phase" usage is enabled openwb.conf
		# if not right away skip to the ultimate fallback
		if (( slaveModeUseLastChargingPhase == 1)); then

			local previousChargingPhasesArray=(0 0 0 0)
			local previousNumberOfChargingPhases=0

			# get previously charging phases if available, else use all 0 (none)
			if [ -f "${LastChargingPhaseFile}${chargePoint}" ]; then
				previousChargingPhasesString=$(<"${LastChargingPhaseFile}${chargePoint}")
				IFS=',' read -ra previousChargingPhasesArray <<< "$previousChargingPhasesString"
			fi

			# iterate the phases and determine the last charging phase with maximum current
			# if no last charging phase, leaves variables unchagned (i.e. at their default of 0 to trigger ultimate fallback)
			for i in {1..3}; do
				if (( previousChargingPhasesArray[i] == 1 )); then

					previousNumberOfChargingPhases=$(( previousNumberOfChargingPhases + 1 ))

					if (( `echo "${TotalCurrentConsumptionOnPhase[i]} > $TotalCurrentOfChargingPhaseWithMaximumTotalCurrent" | bc` == 1 )); then
						TotalCurrentOfChargingPhaseWithMaximumTotalCurrent=${TotalCurrentConsumptionOnPhase[i]}
						ChargingPhaseWithMaximumTotalCurrent=$i
					fi
				fi
			done
		fi

		# ultimate fallback: use phase with the highest total current
		# (i.e. assume we would start charging on all 3 phases)
		if (( ChargingPhaseWithMaximumTotalCurrent == 0 )); then
			$dbgWrite "$NowItIs: CP${chargePoint}: Previously charging phase unknown or disabled. Using highst of all 3 phases for load management"
			ChargingPhaseWithMaximumTotalCurrent=$PhaseWithMaximumTotalCurrent
			TotalCurrentOfChargingPhaseWithMaximumTotalCurrent=$MaximumTotalCurrent
		else
			NumberOfChargingPhases=$previousNumberOfChargingPhases
			$dbgWrite "$NowItIs: CP${chargePoint}: Previously charging phase #${ChargingPhaseWithMaximumTotalCurrent} has highest current and will be used for load management"
		fi
	fi

	# we must make sure that we don't leave NumberOfChargingPhases at 0 if we couldn't count it up to here
	# so we have to assume worst-case (charging on all three phases)
	if (( NumberOfChargingPhases == 0 )); then
		NumberOfChargingPhases=3
	fi

	$dbgWrite "$NowItIs: CP${chargePoint} (enabled=${LpEnabled}): NumberOfChargingPhases=${NumberOfChargingPhases}, ChargeCurrentOnPhase=${ChargeCurrentOnPhase[@]:1}, ChargingOnPhase=${ChargingOnPhase[@]:1}, charging phase with max total current = ${ChargingPhaseWithMaximumTotalCurrent} @ ${TotalCurrentOfChargingPhaseWithMaximumTotalCurrent} A, CpIsCharging=${CpIsCharging}"

	return 0
}


# sets all the required variables from the ramdisk
# these are the values that are only relevant for slave mode - for other values we obviously rely on loadvars.sh
function setVariablesFromRamdisk() {

	# general use
	NowItIs=$(date +%s)

	# data from local control server - the total allowed current per phase ...
	# ... and optionally the Allowed Peak Power and the Total Power
	AllowedTotalCurrentPerPhase=$(<ramdisk/AllowedTotalCurrentPerPhase)
	if [ -f "ramdisk/AllowedPeakPower" ]; then
		AllowedPeakPower=$(<"ramdisk/AllowedPeakPower")
	else
		AllowedPeakPower=0
	fi
	if [ -f "ramdisk/TotalPower" ]; then
		TotalPowerConsumption=$(<ramdisk/TotalPower)
	else
		TotalPowerConsumption=-1
	fi

	# phase with maximum current
	PhaseWithMaximumTotalCurrent=0
	MaximumTotalCurrent=0

	TotalCurrentConsumptionOnPhase=(0 0 0 0)
	ChargingVehiclesOnPhase=(0 0 0 0)
	for i in {1..3}
	do
		TotalCurrentConsumptionOnPhase[i]=$(<"ramdisk/TotalCurrentConsumptionOnL${i}")
		ChargingVehiclesOnPhase[i]=$(<"ramdisk/ChargingVehiclesOnL${i}")

		if (( `echo "${TotalCurrentConsumptionOnPhase[i]} > $MaximumTotalCurrent" | bc` == 1 )); then
			MaximumTotalCurrent=${TotalCurrentConsumptionOnPhase[i]}
			PhaseWithMaximumTotalCurrent=${i}
		fi
	done

	$dbgWrite "$NowItIs: TotalCurrentConsumptionOnPhase=${TotalCurrentConsumptionOnPhase[@]:1}, Phase with max total current = ${PhaseWithMaximumTotalCurrent} @ ${MaximumTotalCurrent} A"

	# heartbeat
	Heartbeat=$(<ramdisk/heartbeat)
	PreviousMaximumTotalCurrent=$(<ramdisk/PreviousMaximumTotalCurrent)
	IFS=',' read -ra previousTotalCurrentAndTimestampArray <<< "$PreviousMaximumTotalCurrent"
	heartbeatMissingFor=$(( NowItIs - previousTotalCurrentAndTimestampArray[1] ))

	return 0
}


# checks whether heartbeat from local control server is available
# if not, steps all charging immediately
# Heartbeat is always checked looking for regular change of total current reported by control server for phase #1
function checkControllerHeartbeat() {

	local comparisonValue="${MaximumTotalCurrent}"

	if [ -f "ramdisk/LastControllerPublish" ]; then
		comparisonValue=$(<"ramdisk/LastControllerPublish")
	fi

	if [[ "${comparisonValue}" == "${previousTotalCurrentAndTimestampArray[0]}" ]]; then
		$dbgWrite "$NowItIs: WARNING: Local Control Server Heartbeat: Comparison value (${comparisonValue}) same as previous (${previousTotalCurrentAndTimestampArray[0]}) for $heartbeatMissingFor s (timeout $HeartbeatTimeout)"

		if (( heartbeatMissingFor > HeartbeatTimeout )); then
			if (( Heartbeat == 1 )) || (( debug == 2 )); then
				echo "$NowItIs: Slave Mode: HEARTBEAT ERROR: Comparison value (${comparisonValue}) not changed by local control server for $heartbeatMissingFor > $HeartbeatTimeout seconds. STOP CHARGING IMMEDIATELY"
			fi
			echo "Slave Mode: Zentralserver Ausfall, Ladung auf allen LP deaktiviert !" > ramdisk/lastregelungaktiv
			echo "0" > ramdisk/heartbeat
			callSetCurrent 0 0
			exit 1
		else
			echo "1" > ramdisk/heartbeat
		fi
	else
		$dbgWrite "$NowItIs: Comparison value (${comparisonValue}) different from previous (${previousTotalCurrentAndTimestampArray[0]}). Heartbeat OK after ${heartbeatMissingFor} s."

		if (( Heartbeat == 0 )); then
			echo "$NowItIs: Slave Mode: HEARTBEAT RETURNED: After $heartbeatMissingFor seconds"
		fi

		echo "${comparisonValue},$NowItIs" > ramdisk/PreviousMaximumTotalCurrent
		echo "1" > ramdisk/heartbeat
	fi

	return 0
}


# calls "setCurrent" with correct parameters for given charge point
# needed because the charge point parameter of setCurrent is not a number but a string like m, s1, s2, lp4, lp...
function callSetCurrent() {

	# the new current to set is our first parameter
	declare -i -r currentToSet=$1

	# the charge point that we're looking at is the second parameter
	# numeric, value of 0 means "all"
	local chargePoint=$2

	# we have to do a slightly ugly if-else-cascade to set the charge point selector for set-current.sh
	if (( chargePoint == 0 )); then
		local chargePointString="all"
	elif (( chargePoint == 1 )); then
		local chargePointString="m"
	elif (( chargePoint == 2 )); then
		local chargePointString="s1"
	elif (( chargePoint == 3 )); then
		local chargePointString="s2"
	elif (( chargePoint >= 4 )); then
		local chargePointString="lp${chargePoint}"
	else
		echo "$NowItIs: Slave Mode charge current set ERROR: Charge Point #${chargePoint} is not supported"
		return 1
	fi

	$dbgWrite "$NowItIs: callSetCurrent(${currentToSet}, ${chargePoint}): Calling runs/set-current.sh ${currentToSet} ${chargePointString}"

	runs/set-current.sh $currentToSet "${chargePointString}"

	return 0
}
