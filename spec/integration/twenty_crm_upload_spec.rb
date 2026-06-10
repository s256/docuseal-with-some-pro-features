# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeClass, RSpec/InstanceVariable

# Run with: docker compose -f docker-compose.e2e.yml up
# This spec requires a running Twenty CRM instance.
# It provisions a user, API key, and seed company, then verifies document upload.
RSpec.describe 'Twenty CRM document upload', type: :integration do
  let(:twenty_url) { ENV.fetch('TWENTY_CRM_URL', 'http://twenty-server:3000') }
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user, name: 'Integration Test Contract') }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: user) }

  def unique_pdf_io
    base_pdf = Rails.root.join('spec/fixtures/sample-document.pdf').binread
    unique_pdf = base_pdf + "\n% #{SecureRandom.uuid}\n"
    StringIO.new(unique_pdf)
  end

  def graphql_request(query, variables: {}, token: nil)
    conn = Faraday.new(url: twenty_url)
    response = conn.post('/metadata') do |req|
      req.headers['Content-Type'] = 'application/json'
      req.headers['Authorization'] = "Bearer #{token}" if token
      req.body = { query: query, variables: variables }.to_json
      req.options.timeout = 30
      req.options.open_timeout = 10
    end
    JSON.parse(response.body)
  end

  def provision_twenty_user
    email = 'e2e-test@docuseal.local'
    password = 'TestPass123!@#'

    # Try signup first (fresh instance)
    signup_query = <<~GQL
      mutation SignUp($email: String!, $password: String!) {
        signUp(email: $email, password: $password) {
          tokens { accessOrWorkspaceAgnosticToken { token } }
          availableWorkspaces {
            availableWorkspacesForSignUp { id workspaceUrls { subdomainUrl } }
            availableWorkspacesForSignIn { id workspaceUrls { subdomainUrl } }
          }
        }
      }
    GQL

    result = graphql_request(signup_query, variables: { email: email, password: password })
    data = result.dig('data', 'signUp')

    # If user already exists, sign in instead
    unless data
      signin_query = <<~GQL
        mutation SignIn($email: String!, $password: String!) {
          signIn(email: $email, password: $password) {
            tokens { accessOrWorkspaceAgnosticToken { token } }
            availableWorkspaces {
              availableWorkspacesForSignUp { id workspaceUrls { subdomainUrl } }
              availableWorkspacesForSignIn { id workspaceUrls { subdomainUrl } }
            }
          }
        }
      GQL

      signin_result = graphql_request(signin_query, variables: { email: email, password: password })
      data = signin_result.dig('data', 'signIn')
      raise "Twenty auth failed: #{signin_result}" unless data
    end

    access_token = data.dig('tokens', 'accessOrWorkspaceAgnosticToken', 'token')
    workspaces = data.dig('availableWorkspaces', 'availableWorkspacesForSignIn') || []

    return sign_into_existing_workspace(workspaces.first, access_token) if workspaces.any?

    create_and_activate_workspace(access_token)
  end

  def sign_into_existing_workspace(workspace, _agnostic_token)
    # Use signUpInWorkspace (works for existing users too) to get a login token
    login_query = <<~GQL
      mutation SignUpInWorkspace($email: String!, $password: String!, $workspaceId: UUID!) {
        signUpInWorkspace(email: $email, password: $password, workspaceId: $workspaceId) {
          loginToken { token }
        }
      }
    GQL

    login_result = graphql_request(login_query, variables: {
                                     email: 'e2e-test@docuseal.local',
                                     password: 'TestPass123!@#',
                                     workspaceId: workspace['id']
                                   })
    login_token = login_result.dig('data', 'signUpInWorkspace', 'loginToken', 'token')
    raise "Twenty signUpInWorkspace failed: #{login_result}" unless login_token

    origin = workspace.dig('workspaceUrls', 'subdomainUrl') || twenty_url
    exchange_for_access_token(login_token, origin, workspace['id'])
  end

  def create_and_activate_workspace(access_token)
    workspace_query = <<~GQL
      mutation SignUpInNewWorkspace {
        signUpInNewWorkspace {
          loginToken { token }
          workspace { id workspaceUrls { subdomainUrl } }
        }
      }
    GQL

    ws_result = graphql_request(workspace_query, token: access_token)
    ws_data = ws_result.dig('data', 'signUpInNewWorkspace')
    raise "Twenty workspace creation failed: #{ws_result}" unless ws_data

    login_token = ws_data.dig('loginToken', 'token')
    workspace_id = ws_data.dig('workspace', 'id')
    origin = ws_data.dig('workspace', 'workspaceUrls', 'subdomainUrl') || twenty_url

    result = exchange_for_access_token(login_token, origin, workspace_id)

    # Activate workspace (creates standard roles, objects, etc.)
    activate_query = <<~GQL
      mutation ActivateWorkspace($displayName: String!) {
        activateWorkspace(data: { displayName: $displayName }) { id }
      }
    GQL
    graphql_request(activate_query, variables: { displayName: 'DocuSeal E2E Test' }, token: result[:access_token])

    result
  end

  def exchange_for_access_token(login_token, origin, workspace_id)
    exchange_query = <<~GQL
      mutation GetAuthTokensFromLoginToken($loginToken: String!, $origin: String!) {
        getAuthTokensFromLoginToken(loginToken: $loginToken, origin: $origin) {
          tokens { accessOrWorkspaceAgnosticToken { token } }
        }
      }
    GQL

    exchange_result = graphql_request(exchange_query, variables: { loginToken: login_token, origin: origin })
    exchange_data = exchange_result.dig('data', 'getAuthTokensFromLoginToken')
    raise "Twenty token exchange failed: #{exchange_result}" unless exchange_data

    ws_access_token = exchange_data.dig('tokens', 'accessOrWorkspaceAgnosticToken', 'token')
    { access_token: ws_access_token, workspace_id: workspace_id }
  end

  def create_api_key(access_token:)
    # Get roles to find the admin role
    roles_result = graphql_request('query { getRoles { id label } }', token: access_token)
    roles = roles_result.dig('data', 'getRoles') || []
    admin_role = roles.find { |r| r['label'] == 'Admin' }
    raise "Could not find admin role. Available: #{roles}" unless admin_role

    # Create API key
    create_query = <<~GQL
      mutation CreateApiKey($input: CreateApiKeyInput!) {
        createApiKey(input: $input) { id expiresAt }
      }
    GQL

    expires_at = 1.year.from_now.iso8601
    input = { name: 'E2E Test Key', expiresAt: expires_at, roleId: admin_role['id'] }
    create_result = graphql_request(create_query,
                                    variables: { input: input },
                                    token: access_token)
    api_key_data = create_result.dig('data', 'createApiKey')
    raise "Twenty API key creation failed: #{create_result}" unless api_key_data

    # Generate token for the API key
    token_query = <<~GQL
      mutation GenerateApiKeyToken($apiKeyId: UUID!, $expiresAt: String!) {
        generateApiKeyToken(apiKeyId: $apiKeyId, expiresAt: $expiresAt) { token }
      }
    GQL

    token_result = graphql_request(token_query,
                                   variables: { apiKeyId: api_key_data['id'], expiresAt: expires_at },
                                   token: access_token)
    token_data = token_result.dig('data', 'generateApiKeyToken')
    raise "Twenty API key token generation failed: #{token_result}" unless token_data

    token_data['token']
  end

  def find_file_field_metadata_id(api_key)
    conn = Faraday.new(url: twenty_url)
    response = conn.get('/rest/metadata/objects') do |req|
      req.headers['Authorization'] = "Bearer #{api_key}"
      req.options.timeout = 10
    end

    objects_list = JSON.parse(response.body)
    objects_list = objects_list['data'] if objects_list.is_a?(Hash) && objects_list.key?('data')

    attachment_obj = objects_list.find { |o| o['nameSingular'] == 'attachment' }
    return nil unless attachment_obj

    fields = attachment_obj['fields'] || []
    file_field = fields.find { |f| f['name'] == 'file' }
    file_field&.dig('id')
  end

  def create_twenty_company(api_key, name:, domain:)
    conn = Faraday.new(url: twenty_url)

    # Use a unique name per test run to avoid duplicate detection
    unique_name = "#{name} #{SecureRandom.hex(4)}"
    unique_domain = "#{SecureRandom.hex(4)}.#{domain}"

    response = conn.post('/rest/companies') do |req|
      req.headers['Authorization'] = "Bearer #{api_key}"
      req.headers['Content-Type'] = 'application/json'
      req.body = { name: unique_name, domainName: { primaryLinkUrl: unique_domain } }.to_json
      req.options.timeout = 10
    end

    raise "Twenty company creation failed (HTTP #{response.status}): #{response.body}" if response.status >= 400

    data = JSON.parse(response.body)
    data.dig('data', 'createCompany', 'id') || data.dig('data', 'id') || data['id']
  end

  before do
    WebMock.allow_net_connect!

    begin
      health = Faraday.get("#{twenty_url}/healthz") { |req| req.options.open_timeout = 5 }
      skip "Twenty CRM not available (HTTP #{health.status})" unless health.status == 200
    rescue Faraday::Error
      skip 'Twenty CRM not available (connection failed)'
    end

    # Provision: user → API key → company
    credentials = provision_twenty_user
    @twenty_api_key = create_api_key(access_token: credentials[:access_token])
    @twenty_company_id = create_twenty_company(@twenty_api_key, name: 'E2E Test GmbH', domain: 'e2e-test.local')
    @twenty_file_field_metadata_id = find_file_field_metadata_id(@twenty_api_key)

    # If we couldn't discover the file field ID, use a placeholder — the upload will still test
    # the API connectivity even if the GraphQL file upload step has issues
    @twenty_file_field_metadata_id ||= '00000000-0000-0000-0000-000000000000'

    # Configure ENV for the upload module
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TWENTY_CRM_URL').and_return(twenty_url)
    allow(ENV).to receive(:[]).with('TWENTY_CRM_API_KEY').and_return(@twenty_api_key)
    allow(ENV).to receive(:[]).with('TWENTY_CRM_FILE_FIELD_METADATA_ID').and_return(@twenty_file_field_metadata_id)

    # Mark all submitters as completed and set company ID in metadata
    submission.submitters.each_with_index do |submitter, i|
      submitter.update!(
        completed_at: i.hours.ago,
        name: "Test Signer #{i + 1}",
        metadata: (i.zero? ? { 'twenty_company_id' => @twenty_company_id } : {})
      )
    end

    # Attach a combined document
    blob = ActiveStorage::Blob.create_and_upload!(
      io: unique_pdf_io,
      filename: "twenty-e2e-test-#{SecureRandom.hex(4)}.pdf",
      content_type: 'application/pdf'
    )
    ActiveStorage::Attachment.create!(blob:, name: 'combined_document', record: submission)
  end

  after do
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  it 'uploads a signed document to Twenty CRM and creates an attachment' do
    result = Submissions::UploadToTwenty.call(submission)

    expect(result).to be_present
    expect(result.first).to be_a(String)
  end

  it 'uploads via the background job without error' do
    expect do
      UploadToTwentyJob.new.perform('submission_id' => submission.id)
    end.not_to raise_error
  end

  it 'attachment is linked to the correct company' do
    Submissions::UploadToTwenty.call(submission)

    # Verify by listing attachments and finding ours
    conn = Faraday.new(url: twenty_url)
    response = conn.get('/rest/attachments') do |req|
      req.headers['Authorization'] = "Bearer #{@twenty_api_key}"
      req.options.timeout = 10
    end

    expect(response.status).to be < 400
    attachments = JSON.parse(response.body)
    records = attachments.dig('data', 'attachments') || attachments['data'] || []

    # Find attachment linked to our company
    company_attachments = records.select { |a| a['targetCompanyId'] == @twenty_company_id }
    expect(company_attachments).to be_present
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/InstanceVariable
