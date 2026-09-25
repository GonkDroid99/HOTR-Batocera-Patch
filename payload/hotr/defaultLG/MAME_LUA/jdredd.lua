-- 6Bolt - Fixed the P2 issue, where it was blocking the outputs. Now P1 and P2 are working with outputs
-- Also had to block the attract screen Ammo and Life setting, to stop false recoil on P2
------------------------------------------------------
-- Change those values to adapt to your hardware 	-- 
------------------------------------------------------
RECOIL_PULSE_DURATION_MS = 15
DAMAGED_PULSE_DURATION_MS = 250





------------------------------------------------------
-- Memory Values								 	--
------------------------------------------------------
_Credits_MemoryAddress = 0x3E6CAE
_StartLamp = {0, 0}
_PlayerStatus = {0, 0}
_PlayerLife = {0, 0}
_PlayerAmmo = {0, 0}
_Credits = 0
_GameStatus = 0

------------------------------------------------------
-- Used for generating pulses						--
------------------------------------------------------
_RecoilDuration = emu.attotime.from_msec(RECOIL_PULSE_DURATION_MS)
_DamagedDuration = emu.attotime.from_msec(DAMAGED_PULSE_DURATION_MS)
_LastLife = {0, 0}
_LastAmmo = {0, 0}
_Recoil_StartTick = {0, 0}
_Damaged_StartTick = {0, 0}

------------------------------------------------------------------
-- Computing Outputs data based on the game's Memory values 	--
------------------------------------------------------------------
cpu = manager.machine.devices[":maincpu"]
mem = cpu.spaces["program"]

function Compute_Outputs() 

	-- Credits are the same for all
	_Credits = mem:read_u8(_Credits_MemoryAddress);
	
	-- Reading player value based on the ROM
	Read_Outputs()
	
	-- Adding Outputs
	for i=0, 1 do	

		-- Genuine Outputs
--		manager.machine.output:set_value("P" .. (i + 1) .. "_LmpStart", _StartLamp[i])
	
		_GameStatus = mem:read_u32(0x10EDB0)
		-- Used to filter between Attract/Play mode
		if _GameStatus == 0 or _GameStatus == 0x7F000003 then
			-- If Player1 is in play, setting Ammo/Life/Recoil/Damaged outputs
	--		if _PlayerStatus[i] == 1 then
				manager.machine.output:set_value("P" .. (i + 1) .. "_Life", _PlayerLife[i])
				manager.machine.output:set_value("P" .. (i + 1) .. "_Ammo", _PlayerAmmo[i])
			
				if _PlayerAmmo[i] < _LastAmmo[i] and (_LastAmmo[i] ~= 8 and _PlayerAmmo[i] ~= 0) then
					manager.machine.output:set_value("P" .. (i + 1) .. "_CtmRecoil", 1)
					_Recoil_StartTick[i] = manager.machine.time
				end
			
				if _PlayerLife[i] < _LastLife[i] and (_LastLife[i] ~= 1000 and _PlayerLife[i] ~= 0) then
					manager.machine.output:set_value("P" .. (i + 1) .. "_Damaged", 1)
					_Damaged_StartTick[i] = manager.machine.time
				end
	--		else
--				manager.machine.output:set_value("P" .. (i + 1) .. "_Life", 0)
--				manager.machine.output:set_value("P" .. (i + 1) .. "_Ammo", 0)
--			end
		end
		
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

	manager.machine.output:set_value("Credits", _Credits)
	
	
--	DisplayDebugString()
	
end


function Read_Outputs() 

--	bOutputs = mem:read_u8(0x005D0540)
	

	for i=0, 1 do
--		_PlayerStatus[i] = mem:read_u8(0x00502088 + (i * 0x04))
		_PlayerLife[i] = mem:read_u16(0x10ED4E + (i * 0x48))
		_PlayerAmmo[i] = mem:read_u8(0x10ED5D + (i * 0x48))	
--		_StartLamp[i] = mem:read_u32(0x10EDB0) 
	end
	
end

----------------------------------------------------------
-- Draw the text RED (0xffff0000) on BLACK (0xff000000)	--
-- Format: 0xaarrggbb where a = alpha,					--
----------------------------------------------------------
function DisplayDebugString()

	s = manager.machine.screens[":screen"]
	s:draw_text(0, 0, string.format("CREDITS : %d", _Credits), 0xffff0000, 0xff000000)
--	s:draw_text(0, 15, string.format("GameStatus : %d", _GameStatus), 0xffff0000, 0xff000000)
	for i=0, 1 do
--		s:draw_text(0, 15 + (i * 60), string.format("P" .. (i + 1) .. "_StartLamp : %d", _StartLamp[i]), 0xffff0000, 0xff000000)
--		s:draw_text(0, 30 + (i * 60), string.format("P" .. (i + 1) .. "_STATUS : %d", _PlayerStatus[i]), 0xffff0000, 0xff000000)
		s:draw_text(0, 15 + (i * 60), string.format("P" .. (i + 1) .. "_Life : %d", _PlayerLife[i]), 0xffff0000, 0xff000000)
		s:draw_text(0, 30 + (i * 60), string.format("P" .. (i + 1) .. "_Ammo : %d", _PlayerAmmo[i]), 0xffff0000, 0xff000000)
	end
	
end



-- Initializing values to make MameHooker display them at start
--manager.machine.output:set_value("P1_LmpStart", 0)
--manager.machine.output:set_value("P2_LmpStart", 0)
manager.machine.output:set_value("P1_Ammo", 0)
manager.machine.output:set_value("P2_Ammo", 0)
manager.machine.output:set_value("P1_CtmRecoil", 0)
manager.machine.output:set_value("P2_CtmRecoil", 0)
manager.machine.output:set_value("P1_Life", 0)
manager.machine.output:set_value("P2_Life", 0)
manager.machine.output:set_value("P1_Damaged", 0)
manager.machine.output:set_value("P2_Damaged", 0)
manager.machine.output:set_value("Credits", 0)

-- Initializing arrays	
for i=0, 1 do
	_PlayerLife[i] = 0
	_LastLife[i] = 0
	_PlayerAmmo[i] = 0
	_LastAmmo[i] = 0
end

-- Registering callback for Frame-Update
emu.register_frame_done(Compute_Outputs, "frame")


