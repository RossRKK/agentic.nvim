local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local SessionPicker = require("agentic.session_picker")
local SessionRegistry = require("agentic.session_registry")

--- @class agentic.SessionRestoreContext
--- @field agent agentic.acp.ACPClient
--- @field provider_name agentic.UserConfig.ProviderName
--- @field source? agentic.SessionManager

--- @class agentic.SessionRestore
local SessionRestore = {}

--- @return agentic.SessionRestoreContext|nil context
local function resolve_context()
    local source = SessionRegistry.current()
    if source then
        return {
            agent = source.agent,
            provider_name = source.provider_name,
            source = source,
        }
    end

    local agent = AgentInstance.get_instance(Config.provider)
    if not agent then
        return nil
    end

    return {
        agent = agent,
        provider_name = Config.provider,
    }
end

--- @param context agentic.SessionRestoreContext
--- @param session_id string
--- @param title string|nil
--- @param timestamp string|integer|nil
local function restore(context, session_id, title, timestamp)
    SessionRegistry.restore(
        context.source,
        context.agent,
        context.provider_name,
        {
            kind = "load",
            session_id = session_id,
            title = title,
            timestamp = timestamp,
        }
    )
end

function SessionRestore.show_picker()
    local context = resolve_context()
    if not context then
        return
    end

    SessionPicker.pick(context.agent, vim.fn.getcwd(), function(choice)
        restore(context, choice.session_id, choice.title, choice.updated_at)
    end)
end

--- @param session_id string
function SessionRestore.restore_by_id(session_id)
    local context = resolve_context()
    if not context then
        return
    end

    context.agent:when_ready(function()
        restore(context, session_id, nil, nil)
    end, SessionPicker.notify_readiness_failure("restore session"))
end

return SessionRestore
