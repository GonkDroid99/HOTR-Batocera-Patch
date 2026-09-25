-- 6Bolt - modified script to block outputs during boot up, to stop false recoil and rumble
-- Also, got P3 added, since game is 3 players.

-- When True, allows the Light Gun Signals Through
_gameStarted = false
--_startedGame = 0
--_bootUp = 0
_coinHigh = false
_coinLow = false

------------------------------------------------------
-- Change those values to adapt to your hardware 	-- 
------------------------------------------------------
RECOIL_PULSE_DURATION_MS = 15
DAMAGED_PULSE_DURATION_MS = 250





------------------------------------------------------
-- Memory Values								 	--
------------------------------------------------------
_Credits_MemoryAddress = 0x2189C1
_StartLamp = {0, 0, 0}
_PlayerStatus = {0, 0, 0}
_PlayerLife = {0, 0, 0}
_PlayerAmmo = {0, 0, 0}
_Credits = 0

------------------------------------------------------
-- Used for generating pulses						--
------------------------------------------------------
_RecoilDuration = emu.attotime.from_msec(RECOIL_PULSE_DURATION_MS)
_DamagedDuration = emu.attotime.from_msec(DAMAGED_PULSE_DURATION_MS)
_LastLife = {0, 0, 0}
_LastAmmo = {0, 0, 0}
_Recoil_StartTick = {0, 0, 0}
_Damaged_StartTick = {0, 0, 0}

------------------------------------------------------------------
-- Computing Outputs data based on the game's Memory values 	--
------------------------------------------------------------------
cpu = manager.machine.devices[":maincpu"]
mem = cpu.spaces["program"]

function Compute_Outputs() 

	-- Credits are the same for all
	_Credits = mem:read_u8(_Credits_MemoryAddress);
	
	--manager.machine.output:set_value("StartGame", _startedGame)
	--manager.machine.output:set_value("BootUp", _bootUp)
	
	-- Reading player value based on the ROM
	Read_Outputs()
	
	if _gameStarted == true then
	
		-- Adding Outputs
		for i=0, 2 do	
		
			-- Genuine Outputs
--			manager.machine.output:set_value("P" .. (i + 1) .. "_LmpStart", _StartLamp[i])
	
--			GameStatus = mem:read_u8(0x0050003D) -- not needed for CryptKiller (I hope)
			-- Used to filter between Attract/Play mode
	--		if GameStatus == 1 then
				-- If Player1 is in play, setting Ammo/Life/Recoil/Damaged outputs
	--		if _PlayerStatus[i] == 1 then
				manager.machine.output:set_value("P" .. (i + 1) .. "_Life", _PlayerLife[i])
				manager.machine.output:set_value("P" .. (i + 1) .. "_Ammo", _PlayerAmmo[i])
			
				if _PlayerAmmo[i] < _LastAmmo[i] then
					mem:write_direct_u16(0x8001512A,0x1400) -- disable white flash, here b/c doing it at startup gets overwritten by game POST
					manager.machine.output:set_value("P" .. (i + 1) .. "_CtmRecoil", 1)
					_Recoil_StartTick[i] = manager.machine.time
				end
			
				if _PlayerLife[i] < _LastLife[i] then
					manager.machine.output:set_value("P" .. (i + 1) .. "_Damaged", 1)
					_Damaged_StartTick[i] = manager.machine.time
				end
	--		else
--				manager.machine.output:set_value("P" .. (i + 1) .. "_Life", 0)
--				manager.machine.output:set_value("P" .. (i + 1) .. "_Ammo", 0)
--			end
--		end
		
		-- Resetting backup values for next frame comparison
		_LastLife[i] = _PlayerLife[i]
		_LastAmmo[i] = _PlayerAmmo[i]
		
		-- Creating "Pulse" signals by resetting Recoil/Damaged after a period of time
		if manager.machine.output:get_value("P" .. (i + 1) .. "_CtmRecoil") == 1 then
			RecoilDelay = manager.machine.time - _Recoil_StartTick[i]
			if RecoilDelay > _RecoilDuration then
				manager.machine.output:set_value("P" .. (i + 1) .. "_CtmRecoil", 0)
			end
		end
		if manager.machine.output:get_value("P" .. (i + 1) .. "_Damaged") == 1 then
			DamagedDelay = manager.machine.time - _Damaged_StartTick[i]
			if DamagedDelay > _DamagedDuration then
				manager.machine.output:set_value("P" .. (i + 1) .. "_Damaged", 0)
			end
		end
		
		end
		
    else
		CheckBootUp()
	end

	manager.machine.output:set_value("Credits", _Credits)
	
	
--	DisplayDebugString()
	
end


function Read_Outputs() 

--	bOutputs = mem:read_u8(0x005D0540)
	
	for i=0, 2 do
--		_PlayerStatus[i] = mem:read_u8(0x00502088 + (i * 0x04))
		_PlayerLife[i] = mem:read_u8(0x2377CC + (i * 0x58))
		_PlayerAmmo[i] = mem:read_u8(0x2377D3 + (i * 0x58))	
--		_StartLamp[i] = bOutputs >> (2 + i) & 0x01

	end
	
end


function CheckBootUp() 

	if _coinHigh == false then
		if _Credits > 0 then
			_coinHigh = true
			--_bootUp = 1
		end
	else
		if _Credits == 0 then
			_coinLow = true
			--_bootUp = 0
			--_startedGame = 1
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
	for i=0, 2 do
--		s:draw_text(0, 15 + (i * 60), string.format("P" .. (i + 1) .. "_StartLamp : %d", _StartLamp[i]), 0xffff0000, 0xff000000)
--		s:draw_text(0, 30 + (i * 60), string.format("P" .. (i + 1) .. "_STATUS : %d", _PlayerStatus[i]), 0xffff0000, 0xff000000)
		s:draw_text(0, 45 + (i * 60), string.format("P" .. (i + 1) .. "_Life : %d", _PlayerLife[i]), 0xffff0000, 0xff000000)
		s:draw_text(0, 60 + (i * 60), string.format("P" .. (i + 1) .. "_Ammo : %d", _PlayerAmmo[i]), 0xffff0000, 0xff000000)
	end
	
end



-- Initializing values to make MameHooker display them at start
--manager.machine.output:set_value("P1_LmpStart", 0)
--manager.machine.output:set_value("P2_LmpStart", 0)
manager.machine.output:set_value("P1_Ammo", 0)
manager.machine.output:set_value("P2_Ammo", 0)
manager.machine.output:set_value("P3_Ammo", 0)
manager.machine.output:set_value("P1_CtmRecoil", 0)
manager.machine.output:set_value("P2_CtmRecoil", 0)
manager.machine.output:set_value("P3_CtmRecoil", 0)
manager.machine.output:set_value("P1_Life", 0)
manager.machine.output:set_value("P2_Life", 0)
manager.machine.output:set_value("P3_Life", 0)
manager.machine.output:set_value("P1_Damaged", 0)
manager.machine.output:set_value("P2_Damaged", 0)
manager.machine.output:set_value("P3_Damaged", 0)
manager.machine.output:set_value("Credits", 0)
--manager.machine.output:set_value("StartGame", 0)
--manager.machine.output:set_value("BootUp", 0)

-- Initializing arrays	
for i=0, 2 do
	_PlayerLife[i] = 0
	_LastLife[i] = 0
	_PlayerAmmo[i] = 0
	_LastAmmo[i] = 0
end

-- Disable white flash
mem:write_direct_u16(0x8001512A,0x1400) -- gets overwritten during game POST, hacked it into recoil above

-- Registering callback for Frame-Update
emu.register_frame_done(Compute_Outputs, "frame")


