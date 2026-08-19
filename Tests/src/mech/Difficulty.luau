--!strict

-- MechBattlegrounds difficulty table, transcribed from the source's
-- Behaviors/Regular.lua (difficulty gates + cooldowns) and Bot.lua constants.
-- Pure data; the policy reads capabilities from here instead of if/elseif
-- difficulty checks scattered through the chain.
--
-- Source values:
--   attack cooldown (after a MISS): Easy 6 / Normal 3 / Hard 1.5
--   skill cooldown (AI-side, on top of real skill cooldowns):
--     basic:      Easy 12 / Normal 9 / Hard 6
--     overclock:  Easy 26 / Normal 20 / Hard 15
--   shared cooldown (Easy only): 5s after any skill or full combo
--   combo length: Easy 3, Normal 4, Hard 4 (+ last hit chains into a skill)
--   dash gap-closer + ragdoll-cancel: Normal+
--   block: Hard only, hold 3-4s
--   ranges: basic attack < 25 @ 20deg cone; dash >= 120 (double >= 180);
--           closeness threshold 70

local Difficulty = {}

export type Spec = {
	name: string,
	attackMissCooldown: number,
	skillCooldown: number,
	overclockSkillCooldown: number,
	sharedCooldown: number?, -- Easy's everything-stops penalty
	comboLength: number,
	comboIntoSkill: boolean, -- Hard: last combo hit chains a skill
	canDash: boolean,
	canBlock: boolean,
	canRagdollCancel: boolean,
}

Difficulty.Easy = {
	name = "Easy",
	attackMissCooldown = 6,
	skillCooldown = 12,
	overclockSkillCooldown = 26,
	sharedCooldown = 5,
	comboLength = 3,
	comboIntoSkill = false,
	canDash = false,
	canBlock = false,
	canRagdollCancel = false,
} :: Spec

Difficulty.Normal = {
	name = "Normal",
	attackMissCooldown = 3,
	skillCooldown = 9,
	overclockSkillCooldown = 20,
	sharedCooldown = nil,
	comboLength = 4,
	comboIntoSkill = false,
	canDash = true,
	canBlock = false,
	canRagdollCancel = true,
} :: Spec

Difficulty.Hard = {
	name = "Hard",
	attackMissCooldown = 1.5,
	skillCooldown = 6,
	overclockSkillCooldown = 15,
	sharedCooldown = nil,
	comboLength = 4,
	comboIntoSkill = true,
	canDash = true,
	canBlock = true,
	canRagdollCancel = true,
} :: Spec

-- Shared range/shape constants (Bot.lua / Regular.lua).
Difficulty.BASIC_ATTACK_RANGE = 25
Difficulty.BASIC_ATTACK_CONE = math.rad(20)
Difficulty.DASH_MIN_DISTANCE = 120
Difficulty.DOUBLE_DASH_DISTANCE = 180
Difficulty.DASH_ALIGN_CONE = math.rad(10)
Difficulty.BLOCK_RANGE = 25
Difficulty.CLOSENESS_THRESHOLD = 70
Difficulty.ORBIT_SLOTS = 8
Difficulty.ORBIT_RADIUS_CLOSE = 20 -- with a closeness token
Difficulty.ORBIT_RADIUS_FAR = 70 -- without
Difficulty.ORBIT_REROLL_SECONDS = 10
Difficulty.STANDOFF_MIN = 25 -- no-token bots hover facing in 25..70
Difficulty.BLOCK_HOLD_MIN = 3
Difficulty.BLOCK_HOLD_MAX = 4
Difficulty.BLOCK_COOLDOWN = 6 -- (source has the os.clock bug; we implement the intent)
Difficulty.RAGDOLL_CANCEL_DELAY = 1 -- + random(0.25, 1.5) jitter

-- Token caps (AIManager.lua): per TARGET player.
Difficulty.MAX_ATTACK_TOKENS = 2
Difficulty.MAX_SKILL_TOKENS = 2
Difficulty.MAX_CLOSENESS_TOKENS = 3
Difficulty.CLOSENESS_TOKEN_TTL = 5

return Difficulty
