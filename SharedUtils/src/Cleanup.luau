local Cleanup = {}
Cleanup.__index = Cleanup

function Cleanup.CreateProfile()
	local self = setmetatable({ cleanupCalls = {}, cleanupConnections = {}, cleanupInstances = {} }, Cleanup)
	return self
end

function Cleanup:AddInstance(name, instance: Instance)
	if self.cleanupInstances[name] then
		warn(`Cleanup instance named {name} already exists`)
	end
	self.cleanupInstances[name] = instance
end

function Cleanup:RemoveInstance(name)
	self.cleanupInstances[name] = nil
end

function Cleanup:AddCleanupCall(name, cleanupCall)
	if self.cleanupCalls[name] then
		warn(`Cleanup call named {name} already exists`)
	end
	self.cleanupCalls[name] = cleanupCall
end

function Cleanup:RemoveCleanupCall(name)
	self.cleanupCalls[name] = nil
end

function Cleanup:CleanupCall(name)
	if self.cleanupCalls[name] then
		-- print(`Cleaning up {name}`)
		self.cleanupCalls[name]()
	end
	self.cleanupCalls[name] = nil
end

function Cleanup:AddCleanupConnection(name, cleanupConnection)
	if self.cleanupConnections[name] then
		warn(`Cleanup connection named {name} already exists`)
		return
	end
	self.cleanupConnections[name] = cleanupConnection
end

function Cleanup:RemoveCleanupConnection(name)
	self.cleanupConnections[name] = nil
end

function Cleanup:CleanupConnection(name)
	if self.cleanupConnections[name] and self.cleanupConnections[name].Connected then
		-- print(`Cleaning up {name}`)
		self.cleanupConnections[name]:Disconnect()
	end
	self.cleanupConnections[name] = nil
end

function Cleanup:PerformCleanup()
	for name, _ in self.cleanupConnections do
		self:CleanupConnection(name)
	end
	for name, cleanupInstance in self.cleanupInstances do
		if cleanupInstance and cleanupInstance.Parent ~= nil then
			cleanupInstance:Destroy()
			self.cleanupInstances[name] = nil
		end
	end
	for name, cleanupCall in self.cleanupCalls do
		if cleanupCall then
			-- print(`Cleaning up {name}`)
			self.cleanupCalls[name] = nil
			cleanupCall()
		end
	end
end

function Cleanup:Destroy()
	self:PerformCleanup()
	setmetatable(self, nil)
end

return Cleanup
