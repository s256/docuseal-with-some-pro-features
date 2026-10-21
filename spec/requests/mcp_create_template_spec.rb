# frozen_string_literal: true

require 'rails_helper'

describe 'MCP create_template' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:mcp_token) { McpToken.create!(user:, name: 'Test') }

  before do
    create(:account_config, account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)
  end

  it 'assigns the user team to the created template' do
    body = {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: 'create_template', arguments: { name: 'MCP Template' } }
    }

    headers = { 'Authorization' => "Bearer #{mcp_token.token}", 'Content-Type' => 'application/json' }

    expect do
      post '/mcp', params: body.to_json, headers:
    end.to change(Template, :count).by(1)

    template = Template.last

    expect(response).to have_http_status(:ok)
    expect(template.name).to eq('MCP Template')
    expect(user.team_id).to be_present
    expect(template.team_id).to eq(user.team_id)
  end
end
