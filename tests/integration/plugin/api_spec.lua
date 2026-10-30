-- Tests for public API exports in init.lua
describe("Public API", function()
  local codediff

  before_each(function()
    codediff = require("codediff")
  end)

  describe("exports", function()
    it("exports setup function", function()
      assert.is_function(codediff.setup)
    end)

    it("keeps guided review and sign-in without per-block or selected-line APIs", function()
      assert.is_function(codediff.review_start)
      assert.is_function(codediff.ai_login)
      for _, name in ipairs({ "toggle_summary", "toggle_what_summary", "toggle_why_summary", "explain_selection", "summarize", "ai_status" }) do
        assert.is_nil(codediff[name])
      end
      assert.same({ "login", "status" }, vim.fn.getcompletion("CodeDiffAI ", "cmdline"))
    end)

    it("exports next_hunk function", function()
      assert.is_function(codediff.next_hunk)
    end)

    it("exports prev_hunk function", function()
      assert.is_function(codediff.prev_hunk)
    end)

    it("exports next_file function", function()
      assert.is_function(codediff.next_file)
    end)

    it("exports prev_file function", function()
      assert.is_function(codediff.prev_file)
    end)
  end)

  describe("navigation functions", function()
    it("next_hunk returns false when no diff session", function()
      local result = codediff.next_hunk()
      assert.is_false(result)
    end)

    it("prev_hunk returns false when no diff session", function()
      local result = codediff.prev_hunk()
      assert.is_false(result)
    end)

    it("next_file returns false when no explorer/history", function()
      local result = codediff.next_file()
      assert.is_false(result)
    end)

    it("prev_file returns false when no explorer/history", function()
      local result = codediff.prev_file()
      assert.is_false(result)
    end)
  end)
end)
