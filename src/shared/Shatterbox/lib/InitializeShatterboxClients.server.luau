--#selene: allow(unused_variable)
--#selene: allow(multiple_statements)

local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

repeat RunService.Heartbeat:Wait() until ReplicatedStorage:FindFirstChild("BLINK_RELIABLE_REMOTE")

local Shatterbox = require(script.Parent.Parent:WaitForChild("Main"))