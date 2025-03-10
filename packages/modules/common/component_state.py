from typing import List

from helpermodules.auto_str import auto_str


@auto_str
class BatState:
    def __init__(self, imported: float = 0, exported: float = 0, power: float = 0, soc: float = 0):
        self.imported = imported
        self.exported = exported
        self.power = power
        self.soc = soc


@auto_str
class CounterState:
    def __init__(self,
                 imported: float = 0,
                 exported: float = 0,
                 power: float = 0,
                 voltages: List[float] = None,
                 currents: List[float] = None,
                 powers: List[float] = None,
                 power_factors: List[float] = None,
                 frequency: float = 50):
        if voltages is None:
            voltages = [230]*3
        self.voltages = voltages
        if powers is None:
            if currents is None:
                powers = [0]*3
            else:
                powers = [currents[i]*voltages[i] for i in range(0, 3)]
        self.powers = powers
        if currents is None:
            if powers:
                currents = [powers[i]/voltages[i] for i in range(0, 3)]
            else:
                currents = [0]*3
        self.currents = currents
        if power_factors is None:
            power_factors = [0]*3
        self.power_factors = power_factors
        self.imported = imported
        self.exported = exported
        self.power = power
        self.frequency = frequency


@auto_str
class InverterState:
    def __init__(
        self,
        counter: float,
        power: float,
        currents: List[float] = None,
    ):
        if currents is None:
            currents = [0]*3
        self.currents = currents
        self.power = power
        self.counter = counter


@auto_str
class CarState:
    def __init__(self, soc: float):
        self.soc = soc
