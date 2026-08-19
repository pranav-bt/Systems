local ObjectPool = { pools = {}, free = {}, active = {} }

function ObjectPool.CreatePool(tag, object)
	ObjectPool.pools[tag] = object
	ObjectPool.free[tag] = {}
end

function ObjectPool.DoesTagExist(tag)
	return if ObjectPool.pools[tag] then true else false
end

function ObjectPool.Get(tag)
	local instance
	if #ObjectPool.free[tag] > 0 then
		-- print(`Getting cached object with tag {tag}`)
		instance = table.remove(ObjectPool.free[tag])
	else
		instance = ObjectPool.pools[tag]:Clone()
	end

	ObjectPool.active[instance] = tag
	return instance
end

function ObjectPool.Release(object)
	local tag = ObjectPool.active[object]
	table.insert(ObjectPool.free[tag], object)
	ObjectPool.active[object] = nil
	object.Parent = nil
	-- print(`Object with tag {tag} released, free objects count {#ObjectPool.free[tag]}`)
end

function ObjectPool.RegisterObjectFromStringKeys(keys: { string }, object)
	table.sort(keys)
	local keySetId
	for _, key in keys do
		if keySetId == nil then
			keySetId = key
		else
			keySetId = `{keySetId}_{key}`
		end
	end

	if ObjectPool.pools[keySetId] == nil then
		ObjectPool.CreatePool(keySetId, object)
	end

	return keySetId
end

function ObjectPool.FindTagFromStringKeys(keys: { string })
	table.sort(keys)
	local keySetId
	for _, key in keys do
		if keySetId == nil then
			keySetId = key
		else
			keySetId = `{keySetId}_{key}`
		end
	end

	return if ObjectPool.pools[keySetId] then keySetId else false
end

return ObjectPool
