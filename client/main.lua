local config = require 'config.client'
local sharedConfig = require 'config.shared'

---@type table<number, boolean> weapon hashes as a set
WeaponsThatDamagedPlayer = {}

NumInjuries = 0

local playerState = LocalPlayer.state

---@type table<BodyPartKey, Injury>
Injuries = {}

for bodyPartKey in pairs(sharedConfig.bodyParts) do
    local bodyPartStateBag = BODY_PART_STATE_BAG_PREFIX .. bodyPartKey
    Injuries[bodyPartKey] = playerState[bodyPartStateBag]
    AddStateBagChangeHandler(bodyPartStateBag, ('player:%s'):format(cache.serverId), function(_, _, value)
        Injuries[bodyPartKey] = value
    end)
end

function SetInjury(bodyPartKey, severity)
    playerState:set(BODY_PART_STATE_BAG_PREFIX .. bodyPartKey, severity, true)
end

BleedLevel = playerState[BLEED_LEVEL_STATE_BAG] or 0

AddStateBagChangeHandler(BLEED_LEVEL_STATE_BAG, ('player:%s'):format(cache.serverId), function(_, _, value)
    BleedLevel = value
end)

function SetBleedLevel(level)
    playerState:set(BLEED_LEVEL_STATE_BAG, level, true)
end

DeathState = playerState[DEATH_STATE_STATE_BAG] or sharedConfig.deathState.ALIVE

AddStateBagChangeHandler(DEATH_STATE_STATE_BAG, ('player:%s'):format(cache.serverId), function(_, _, value)
    DeathState = value
end)

function SetDeathState(deathState)
    playerState:set(DEATH_STATE_STATE_BAG, deathState, true)
end

BleedTickTimer, AdvanceBleedTimer = 0, 0
FadeOutTimer, BlackoutTimer = 0, 0

---@type number
Hp = nil

DeathTime = 0
LaststandTime = 0
RespawnHoldTime = 5
LastStandDict = "combat@damage@writhe"
LastStandAnim = "writhe_loop"

exports('isDead', function()
    return DeathState == sharedConfig.deathState.DEAD
end)

exports('getLaststand', function()
    return DeathState == sharedConfig.deathState.LAST_STAND
end)

exports('getDeathTime', function()
    return DeathTime
end)

exports('getLaststandTime', function()
    return LaststandTime
end)

exports('getRespawnHoldTimeDeprecated', function()
    return RespawnHoldTime
end)

lib.callback.register('qbx_medical:client:killPlayer', function()
    SetEntityHealth(cache.ped, 0)
end)

---@return boolean isInjuryCausingLimp if injury causes a limp and is damaged.
local function isInjuryCausingLimp()
    for bodyPartKey in pairs(Injuries) do
        if sharedConfig.bodyParts[bodyPartKey].causeLimp then
            return true
        end
    end
    return false
end

---notify the player of damage to their body.
local function doLimbAlert()
    if DeathState ~= sharedConfig.deathState.ALIVE or NumInjuries == 0 then return end

    local limbDamageMsg = ''
    if NumInjuries <= config.alertShowInfo then
        local i = 0
        for bodyPartKey, injury in pairs(Injuries) do
            local bodyPart = sharedConfig.bodyParts[bodyPartKey]
            limbDamageMsg = limbDamageMsg .. Lang:t('info.pain_message', { limb = bodyPart.label, severity = sharedConfig.woundLevels[injury.severity].label})
            i += 1
            if i < NumInjuries then
                limbDamageMsg = limbDamageMsg .. " | "
            end
        end
    else
        limbDamageMsg = Lang:t('info.many_places')
    end
    exports.qbx_core:Notify(limbDamageMsg, 'error')
end

---sets ped animation to limping and prevents running.
function MakePedLimp()
    if not isInjuryCausingLimp() then return end
    lib.requestAnimSet("move_m@injured")
    SetPedMovementClipset(cache.ped, "move_m@injured", 1)
    SetPlayerSprint(cache.playerId, false)
end

--- TODO: this export should not check any conditions, but force the ped to limp instead.
exports('makePedLimp', MakePedLimp)

local function resetMinorInjuries()
    for bodyPartKey, injury in pairs(Injuries) do
        if injury.severity <= 2 then
            SetInjury(bodyPartKey, nil)
            NumInjuries -= 1
        end
    end

    if BleedLevel <= 2 then
        SetBleedLevel(0)
        BleedTickTimer = 0
        AdvanceBleedTimer = 0
        FadeOutTimer = 0
        BlackoutTimer = 0
    end

    SendBleedAlert()
    MakePedLimp()
    doLimbAlert()
end

local function resetAllInjuries()
    for bodyPartKey in pairs(sharedConfig.bodyParts) do
        SetInjury(bodyPartKey, nil)
    end
    NumInjuries = 0
    SetBleedLevel(0)
    BleedTickTimer = 0
    AdvanceBleedTimer = 0
    FadeOutTimer = 0
    BlackoutTimer = 0

    WeaponsThatDamagedPlayer = {}

    SendBleedAlert()
    MakePedLimp()
    doLimbAlert()
    lib.callback('qbx_medical:server:resetHungerAndThirst')
end

---notify the player of bleeding to their body.
function SendBleedAlert()
    if DeathState == sharedConfig.deathState.DEAD or BleedLevel == 0 then return end
    exports.qbx_core:Notify(Lang:t('info.bleed_alert', {bleedstate = sharedConfig.bleedingStates[BleedLevel]}), 'inform')
end

exports('sendBleedAlert', SendBleedAlert)

---adds a bleed to the player and alerts them. Total bleed level maxes at 4.
---@param level 1|2|3|4 speed of the bleed
function ApplyBleed(level)
    if BleedLevel == 4 then return end
    local newBleedLevel = level + BleedLevel
    if newBleedLevel > 4 then
        SetBleedLevel(4)
    else
        SetBleedLevel(newBleedLevel)
    end
    SendBleedAlert()
end

---heals player wounds.
---@param type? "full"|any heals all wounds if full otherwise heals only major wounds.
lib.callback.register('qbx_medical:client:heal', function(type)
    if type == "full" then
        resetAllInjuries()
    else
        resetMinorInjuries()
    end
    exports.qbx_core:Notify(Lang:t('success.wounds_healed'), 'success')
end)

CreateThread(function()
    while true do
        Wait((1000 * config.messageTimer))
        doLimbAlert()
    end
end)

---Revives player, healing all injuries
RegisterNetEvent('qbx_medical:client:playerRevived', function()
    local ped = cache.ped

    if DeathState ~= sharedConfig.deathState.ALIVE then
        local pos = GetEntityCoords(ped, true)
        NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z, GetEntityHeading(ped), true, false)
        SetDeathState(sharedConfig.deathState.ALIVE)
        SetEntityInvincible(ped, false)
        EndLastStand()
    end

    SetEntityMaxHealth(ped, 200)
    SetEntityHealth(ped, 200)
    ClearPedBloodDamage(ped)
    SetPlayerSprint(cache.playerId, true)
    resetAllInjuries()
    ResetPedMovementClipset(ped, 0.0)
    TriggerServerEvent('hud:server:RelieveStress', 100)
    exports.qbx_core:Notify(Lang:t('info.healthy'), 'inform')
end)
