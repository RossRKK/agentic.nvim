local Logger = require("agentic.utils.logger")

--- @class agentic.SessionPicker.Choice
--- @field session_id string
--- @field title? string
--- @field updated_at? string

--- @class agentic.SessionPicker
local SessionPicker = {}

local to_item, format_item

--- @param operation string
--- @return fun(err: agentic.acp.ACPError) callback
function SessionPicker.notify_readiness_failure(operation)
    return function(err)
        Logger.notify(
            "Failed to "
                .. operation
                .. ": "
                .. (err.message or "provider unavailable"),
            vim.log.levels.WARN
        )
    end
end

--- Lists the provider's saved sessions for `cwd` and asks which one to restore.
--- @param agent agentic.acp.ACPClient
--- @param cwd string
--- @param on_choice fun(choice: agentic.SessionPicker.Choice) Not called on cancel
function SessionPicker.pick(agent, cwd, on_choice)
    agent:when_ready(function()
        agent:list_sessions(cwd, function(result, err)
            if err or not result then
                Logger.notify(
                    "Failed to list sessions: "
                        .. (err and err.message or "unknown error"),
                    vim.log.levels.WARN
                )
                return
            end

            if #result.sessions == 0 then
                Logger.notify("No saved sessions found", vim.log.levels.INFO)
                return
            end

            local items = {}
            for _, session in ipairs(result.sessions) do
                items[#items + 1] = to_item(session)
            end

            vim.schedule(function()
                vim.ui.select(items, {
                    prompt = "Select session to restore:",
                    format_item = format_item,
                }, function(choice)
                    if choice then
                        on_choice({
                            session_id = choice.session_id,
                            title = choice.title,
                            updated_at = choice.updated_at,
                        })
                    end
                end)
            end)
        end)
    end, SessionPicker.notify_readiness_failure("list sessions"))
end

--- @param session agentic.acp.SessionInfo
--- @return { display: string, session_id: string, title?: string, updated_at?: string }
function to_item(session)
    local date = session.updatedAt
            and session.updatedAt:sub(1, 16):gsub("T", " ")
        or "unknown date"
    local title = (session.title or "(no title)")
        :gsub("\r\n", " ")
        :gsub("[\r\n]", " ")
        :sub(1, 80)
    return {
        display = string.format(
            "%s - %s - %s",
            date,
            session.sessionId:sub(1, 8),
            title
        ),
        session_id = session.sessionId,
        title = session.title,
        updated_at = session.updatedAt,
    }
end

--- @param item { display: string, session_id: string }
--- @param supports_chunks boolean|nil
--- @return string label
function format_item(item, supports_chunks)
    return supports_chunks and item.display
        or item.display .. " " .. item.session_id
end

return SessionPicker
