-- 6Bolt - made script, using Time Crisis 2 as a template
-- 6Bolt - Found memory loactions for credits, ammo, and life
-- 6Bolt - modified script to block outputs during boot up, to stop false recoil and rumble

------------------------------------------------------
-- Change those values to adapt to your hardware 	-- 
------------------------------------------------------
RECOIL_PULSE_DURATION_MS = 15
DAMAGED_PULSE_DURATION_MS = 250


------------------------------------------------------
-- Memory Values								 	--
------------------------------------------------------
_Credits_MemoryAddress = 0x00E0D2A0
_StartLamp = {0}
_PlayerStatus = {0}
_PlayerLife = {0}
_PlayerAmmo = {0}
_Credits = 0

------------------------------------------------------
-- Used for generating pulses						--
------------------------------------------------------
_RecoilDuration = emu.attotime.from_msec(RECOIL_PULSE_DURATION_MS)
_DamagedDuration = emu.attotime.from_msec(DAMAGED_PULSE_DURATION_MS)
_LastLife = {0}
_LastAmmo = {0}
_Recoil_StartTick = {0}
_Damaged_StartTick = {0}

------------------------------------------------------------------
-- Computing Outputs data based on the game's Memory values 	--
------------------------------------------------------------------
cpu = manager.machine.devices[":maincpu"]
mem = cpu.spaces["program"]

_gameStarted = false
_coinHigh = false
_coinLow = false

function Compute_Outputs() 

	-- Credits are the same for all
	_Credits = mem:read_u16(_Credits_MemoryAddress)
	_PlayerLife[0] = mem:read_u16(0x00E00790)
	_PlayerAmmo[0] = mem:read_u16(0x00E00792)
	_PlayerStatus[0] = mem:read_u16(0xE0D28E)
	
	-- Adding Outputs
	
	
	-- GameStatus = mem:read_u8(0x002ce8af)
		
	if _gameStarted == true then

		manager.machine.output:set_value("P1_Life", _PlayerLife[0])
		manager.machine.output:set_value("P1_Ammo", _PlayerAmmo[0])
			
		if _PlayerAmmo[0] < _LastAmmo[0] then
			manager.machine.output:set_value("P1_CtmRecoil", 1)
			_Recoil_StartTick[0] = manager.machine.time
		end
			
		if _PlayerLife[0] < _LastLife[0] then
			manager.machine.output:set_value("P1_Damaged", 1)
			_Damaged_StartTick[i] = manager.machine.time
		end

	else
		CheckBootUp()
	end
		
	-- Resetting backup values for next frame comparison
	_LastLife[0] = _PlayerLife[0]
	_LastAmmo[0] = _PlayerAmmo[0]
		
	-- Creating "Pulse" signals by resetting Recoil/Damaged after a period of time
	if manager.machine.output:get_value("P1_CtmRecoil") == 1 then
		RecoilDelay = manager.machine.time - _Recoil_StartTick[0]
		if RecoilDelay > _RecoilDuration then
			manager.machine.output:set_value("P1_CtmRecoil", 0)
		end
	end
	if manager.machine.output:get_value("P1_Damaged") == 1 then
		DamagedDelay = manager.machine.time - _Damaged_StartTick[0]
		if DamagedDelay > _DamagedDuration then
			manager.machine.output:set_value("P1_Damaged", 0)
		end
	end
   
	manager.machine.output:set_value("Credits", _Credits)
	
	
	DisplayDebugString()
	
end




function CheckBootUp() 

	if _coinHigh == false then
		if _Credits > 0 then
			_coinHigh = true
		end
	else
		if _Credits == 0 then
			_coinLow = true
			_gameStarted = true;
		end
	end

end


----------------------------------------------------------
-- Draw the text RED (0xffff0000) on BLACK (0xff000000)	--
-- Format: 0xaarrggbb where a = alpha,					--
----------------------------------------------------------
function DisplayDebugString()

	s = manager.machine.screens[":screen"]
	s:draw_text(0, 0, string.format("CREDITS : %d", _Credits), 0xffff0000, 0xff000000)
	i = 0
--	for i=0, 0 do
--		s:draw_text(0, 15 + (i * 60), string.format("P" .. (i + 1) .. "_StartLamp : %d", _StartLamp[i]), 0xffff0000, 0xff000000)
		s:draw_text(0, 30 + (i * 60), string.format("P" .. (i + 1) .. "_STATUS : %s", _PlayerStatus[0]), 0xffff0000, 0xff000000)
		s:draw_text(0, 45 + (i * 60), string.format("P" .. (i + 1) .. "_Life : %d", _PlayerLife[0]), 0xffff0000, 0xff000000)
		s:draw_text(0, 60 + (i * 60), string.format("P" .. (i + 1) .. "_Ammo : %d", _PlayerAmmo[0]), 0xffff0000, 0xff000000)
--	end
	
end



-- Initializing values to make MameHooker display them at start

manager.machine.output:set_value("P1_Ammo", 0)
manager.machine.output:set_value("P1_CtmRecoil", 0)
manager.machine.output:set_value("P1_Life", 0)
manager.machine.output:set_value("P1_Damaged", 0)
manager.machine.output:set_value("Credits", 0)

-- Initializing arrays	
for i=0, 0 do
	_PlayerLife[i] = 0
	_LastLife[i] = 0
	_PlayerAmmo[i] = 0
	_LastAmmo[i] = 0
end

-- mem:write_direct_u64(0x0009192C,0x03E0000800000000) 

-- Registering callback for Frame-Update
emu.register_frame_done(Compute_Outputs, "frame")


