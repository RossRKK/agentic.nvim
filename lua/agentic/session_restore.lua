local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local SessionRegistry = require("agentic.session_registry")

--- @class agentic.SessionRestore
local SessionRestore = {}

--- @param acp_session_id string|nil Asks which saved session when nil
local function resume(acp_session_id)
    local source = SessionRegistry.current()
    if source then
        SessionRegistry.resume(
            source,
            source.agent,
            source.provider_name,
            acp_session_id
        )
        return
    end

    local agent = AgentInstance.get_instance(Config.provider)
    if agent then
        SessionRegistry.resume(nil, agent, Config.provider, acp_session_id)
    end
end

function SessionRestore.show_picker()
    resume(nil)
end

--- @param session_id string
function SessionRestore.restore_by_id(session_id)
    resume(session_id)
end

return SessionRestore
