-----------------------------------------------------------
-- 6Bolt's MAME Lua Script
--
--		Doesn't Run Every Frame
--		Only Updates When Memory Regoins are Written or Timer Events
--		A lot Better for your CPU & Better Performance
--		Anyone Using this Script, Must Keep it Open Sourced!
--		Under the GPL-3.0 License
------------------------------------------------------------


------------------------------------------------------------
-- For Time Crisis on Namco's Super System 22
--
-- RAM Region 0xE00000 to 0xE3FFFF which is 256KB
--
-- Players: 1
-- Ammo 0xE00792 16bit UI
-- Life 0xE00790 16bit UI
-- Credits 0xE0D2A0 16bit UI
--
-- Other Memory Locations
-- 
-- Maybe Game Time 0xE00794
-- Maybe Continue Time 0xE0079C
-- Maybe In-Game Status Bits
-- 0xE0D1D0 = 0 in game, else = 2
-- 0xE0D1D9 = 3 in game, else = 0
-- 0xE0D1F0 = 1 in game, else  = 0
-- 0xE0D28E = 4 in game, else = 0


------------------------------------------------------------
-- Set Up Variables
------------------------------------------------------------

-- Memory Space
space = manager.machine.devices[":maincpu"].spaces["program"]
cpu = manager.machine.devices[":maincpu"]
mem = cpu.spaces["program"]


-- Memory Values
--Game start right after 3 credits
--_StartLamp = {0}
_PlayerLife = {0}
_PlayerAmmo = {0}
_Credits = 0

_LastLife = {0}
_LastAmmo = {0}
_LastCredits = 0


-- Simple Boot Check
_gameStarted = false
_coinHigh = false
_coinLow = false

-- For Write Taps
my_taps = {}


-- Initializing values to make Hook of the Reaper display them at start
manager.machine.output:set_value("P1_Ammo", 0)
manager.machine.output:set_value("P1_CtmRecoil", 0)
manager.machine.output:set_value("P1_Life", 0)
manager.machine.output:set_value("P1_Damaged", 0)
manager.machine.output:set_value("Credits", 0)


-- Install a tap on write to Ammo & Life for Player 1
my_taps.player1_info = mem:install_write_tap(0xE00790, 0xE00793, "player1_info", function(offset, data, mask)
	life = (data >> 16) & 0xFFFF
	ammo = data & 0xFFFF
	lifeMask = (mask >> 16) & 0xFFFF
	ammoMask = mask & 0xFFFF
	
	if _gameStarted == true then
		
		if lifeMask ~= 0 then
			_PlayerLife[0] = life
		end
		if ammoMask ~= 0 then
			_PlayerAmmo[0] = ammo
		end
		
		if _PlayerLife[0] ~= _LastLife[0] then
			manager.machine.output:set_value("P1_Life", _PlayerLife[0])
			if _PlayerLife[0] < _LastLife[0] then
				manager.machine.output:set_value("P1_Damaged", 1)
				manager.machine.output:set_value("P1_Damaged", 0)
			end
		end
		
		if _PlayerAmmo[0] ~= _LastAmmo[0] then
			manager.machine.output:set_value("P1_Ammo", _PlayerAmmo[0])
			if _PlayerAmmo[0] < _LastAmmo[0] then
				manager.machine.output:set_value("P1_CtmRecoil", 1)
				manager.machine.output:set_value("P1_CtmRecoil", 0)
			end
		end
		
		_LastLife[0] = _PlayerLife[0]
		_LastAmmo[0] = _PlayerAmmo[0]
	end
	
end)



-- Install a tap on write to Credits Address
my_taps.credits_info = mem:install_write_tap(0xE0D2A0, 0xE0D2A3, "credits_info", function(offset, data, mask)
	
	-- Check Mask to Make Sure Credits Written Too
	cred = data & 0xFFFF
	credMask = mask & 0xFFFF
	if credMask ~= 0 then
		_Credits = data
	end
	
	-- Only Change Output Signals, when the Data Changed
	if _Credits ~= _LastCredits then
		manager.machine.output:set_value("Credits", _Credits)
	end
	
	_LastCredits = _Credits
	
	-- Boot Check
	if _coinHigh == false then
		if _Credits > 0 then
			_coinHigh = true
		end
	else
		if _Credits == 0 then
			_coinLow = true
			_gameStarted = true
			-- Zero Out Last Ammo and Life Values
			_LastLife[0] = 0
			_LastAmmo[0] = 0
		end
		
	end
	
end)





