local function noYield(callback)
	for _ in
		function()
			return callback()
		end
	do
		break
	end
end

return noYield
