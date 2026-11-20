local assert = require("tests.helpers.assert")

local SubagentActivity = require("agentic.ui.subagent_activity")

describe("agentic.ui.SubagentActivity", function()
    --- @type agentic.ui.SubagentActivity
    local activity

    before_each(function()
        activity = SubagentActivity:new()
    end)

    it("has no summary for a tool call that launched nothing", function()
        assert.is_nil(activity:summarise("toolu_agent"))
    end)

    it("counts each tool call once and names the latest", function()
        activity:record("toolu_agent", {
            tool_call_id = "toolu_1",
            kind = "read",
            argument = "Read init.lua",
        })
        activity:record("toolu_agent", {
            tool_call_id = "toolu_2",
            kind = "execute",
            argument = "git status",
        })
        activity:record("toolu_agent", {
            tool_call_id = "toolu_1",
            status = "completed",
        })

        assert.same({
            tool_call_count = 2,
            latest_kind = "execute",
            latest_argument = "git status",
        }, activity:summarise("toolu_agent"))
    end)

    it("follows a late title of the latest call", function()
        activity:record("toolu_agent", {
            tool_call_id = "toolu_1",
            kind = "execute",
            argument = "Terminal",
        })
        activity:record("toolu_agent", {
            tool_call_id = "toolu_1",
            argument = "make test",
        })

        local summary = activity:summarise("toolu_agent")
        assert.equal("make test", summary and summary.latest_argument)
    end)

    it("keeps each launching tool call's count apart", function()
        activity:record("toolu_a", { tool_call_id = "toolu_1", kind = "read" })
        activity:record("toolu_b", { tool_call_id = "toolu_2", kind = "edit" })
        activity:record("toolu_b", { tool_call_id = "toolu_3", kind = "read" })

        local summary_a = activity:summarise("toolu_a")
        local summary_b = activity:summarise("toolu_b")
        assert.equal(1, summary_a and summary_a.tool_call_count)
        assert.equal(2, summary_b and summary_b.tool_call_count)
    end)

    it("merges updates into the stored call", function()
        local merged = activity:record("toolu_agent", {
            tool_call_id = "toolu_1",
            kind = "edit",
            file_path = "lua/init.lua",
        })
        assert.equal("lua/init.lua", merged.file_path)

        activity:record("toolu_agent", {
            tool_call_id = "toolu_1",
            status = "completed",
        })

        assert.same({
            tool_call_id = "toolu_1",
            kind = "edit",
            file_path = "lua/init.lua",
            status = "completed",
        }, activity:get_tool_call("toolu_1"))
    end)
end)
