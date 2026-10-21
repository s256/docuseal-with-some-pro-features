# frozen_string_literal: true

module Submissions
  module UploadToTwenty
    UploadError = Class.new(StandardError)

    module_function

    def call(submission)
      return unless configured?

      submission.submitters.load unless submission.submitters.loaded?

      company_id = resolve_company_id(submission)

      unless company_id
        Rails.logger.warn("[Twenty CRM] No matching company found for submission #{submission.id}, skipping upload")
        return
      end

      title = build_title(submission)
      results = documents_to_upload(submission, title).map do |attachment, doc_title|
        upload_document(attachment, company_id:, title: doc_title)
      end

      results.compact.presence
    end

    def configured?
      ENV['TWENTY_CRM_URL'].present? &&
        ENV['TWENTY_CRM_API_KEY'].present? &&
        ENV['TWENTY_CRM_FILE_FIELD_METADATA_ID'].present?
    end

    def health_check
      return { configured: false, reachable: false, url: nil, error: nil } unless configured?

      url = ENV['TWENTY_CRM_URL'] # rubocop:disable Style/FetchEnvVar
      response = connection.get('/rest/companies') do |req|
        req.headers['Authorization'] = "Bearer #{ENV['TWENTY_CRM_API_KEY']}" # rubocop:disable Style/FetchEnvVar
        req.params['limit'] = 1
        req.options.timeout = 5
        req.options.open_timeout = 5
      end

      if response.status < 400
        { configured: true, reachable: true, url: url, error: nil }
      else
        { configured: true, reachable: false, url: url, error: "HTTP #{response.status}" }
      end
    rescue Faraday::Error => e
      { configured: true, reachable: false, url: url, error: e.message }
    end

    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    def resolve_company_id(submission)
      metadata_id = submission.submitters.filter_map { |s| s.metadata&.dig('twenty_company_id') }.first
      return metadata_id if metadata_id.present? && metadata_id.match?(UUID_PATTERN)

      nil
    end

    def documents_to_upload(submission, title)
      documents = []

      if submission.combined_document.attached?
        documents << [submission.combined_document, title]
      else
        submission.submitters.select(&:completed_at?).each do |submitter|
          submitter.documents.each do |doc|
            documents << [doc, title]
          end
        end
      end

      documents << [submission.audit_trail, "#{title} - Audit Trail"] if submission.audit_trail.attached?

      documents
    end

    def build_title(submission)
      submitter_names = submission.submitters
                                  .select(&:completed_at?)
                                  .sort_by(&:completed_at)
                                  .filter_map(&:name)
                                  .join(', ')

      template_name = submission.template&.name || 'Document'

      if submitter_names.present?
        "#{template_name} - #{submitter_names}"
      else
        template_name
      end
    end

    def upload_document(attachment, company_id:, title:)
      blob = attachment.blob
      filename = sanitize_filename(blob.filename.to_s)
      label = "#{title}.pdf"

      blob.open do |tempfile|
        file_id = upload_file(tempfile, filename)
        create_attachment(file_id:, label:, company_id:)
      end
    end

    def sanitize_filename(filename)
      filename.gsub(/["\r\n\\]/, '_')
    end

    # Twenty >= 2.19 uploads files directly to storage (createFileUpload -> PUT -> completeFileUpload);
    # Twenty >= 2.39 removed the multipart uploadFilesFieldFile mutation, which stays as a fallback
    # for instances older than 2.19.
    def upload_file(tempfile, filename)
      content = tempfile.read

      direct_upload_file(content, filename)
    rescue LegacyUploadRequired
      legacy_upload_file(content, filename)
    end

    LegacyUploadRequired = Class.new(StandardError)

    CREATE_FILE_UPLOAD_GQL = <<~GQL
      mutation CreateFileUpload($filename: String!, $size: Float!, $fileFolder: FileFolder!, $fieldMetadataId: String) {
        createFileUpload(filename: $filename, size: $size, fileFolder: $fileFolder, fieldMetadataId: $fieldMetadataId) {
          fileId uploadUrl contentType
        }
      }
    GQL

    COMPLETE_FILE_UPLOAD_GQL = <<~GQL
      mutation CompleteFileUpload($fileId: String!) { completeFileUpload(fileId: $fileId) { id } }
    GQL

    def direct_upload_file(content, filename)
      target = metadata_mutation(CREATE_FILE_UPLOAD_GQL,
                                 { filename:, size: content.bytesize, fileFolder: 'FilesField',
                                   fieldMetadataId: ENV['TWENTY_CRM_FILE_FIELD_METADATA_ID'] }, # rubocop:disable Style/FetchEnvVar
                                 'createFileUpload')

      put_to_upload_target(target, content)

      completed = metadata_mutation(COMPLETE_FILE_UPLOAD_GQL, { fileId: target['fileId'] }, 'completeFileUpload')

      completed['id'] || target['fileId']
    end

    def metadata_mutation(query, variables, field)
      response = connection.post('/metadata') do |req|
        req.headers['Authorization'] = "Bearer #{ENV['TWENTY_CRM_API_KEY']}" # rubocop:disable Style/FetchEnvVar
        req.headers['Content-Type'] = 'application/json'
        req.body = { query:, variables: }.to_json
        req.options.timeout = 30
        req.options.open_timeout = 10
      end

      data = response.status < 500 ? JSON.parse(response.body.presence || '{}') : {}
      errors = Array(data['errors']).filter_map { |e| e['message'] }

      raise LegacyUploadRequired if errors.any? { |e| e.include?("Cannot query field \"#{field}\"") }

      result = data.dig('data', field)

      unless response.status < 400 && result
        raise UploadError, "Twenty CRM #{field} failed (HTTP #{response.status}): #{response.body.to_s.truncate(200)}"
      end

      result
    rescue JSON::ParserError
      raise UploadError, "Twenty CRM #{field} returned invalid JSON (HTTP #{response.status})"
    end

    def put_to_upload_target(target, content)
      # uploadUrl is a pre-signed URL (local storage or S3); it must not carry the API key
      upload_url = URI.join("#{ENV['TWENTY_CRM_URL'].to_s.chomp('/')}/", target['uploadUrl'].to_s).to_s

      response = Faraday.new.put(upload_url) do |req|
        req.headers['Content-Type'] = target['contentType'].presence || 'application/pdf'
        req.body = content
        req.options.timeout = 60
        req.options.open_timeout = 10
      end

      return if response.status < 300

      raise UploadError,
            "Twenty CRM file storage upload failed (HTTP #{response.status}): #{response.body.to_s.truncate(200)}"
    end

    def legacy_upload_file(content, filename)
      field_metadata_id = ENV['TWENTY_CRM_FILE_FIELD_METADATA_ID'] # rubocop:disable Style/FetchEnvVar
      boundary = "----DocuSealTwentyUpload#{SecureRandom.hex(16)}"

      gql = 'mutation UploadFilesFieldFile($file: Upload!, $fieldMetadataId: String!) ' \
            '{ uploadFilesFieldFile(file: $file, fieldMetadataId: $fieldMetadataId) { id url } }'

      operations = {
        query: gql,
        variables: { file: nil, fieldMetadataId: field_metadata_id }
      }.to_json

      map = { '0' => ['variables.file'] }.to_json

      body = build_graphql_multipart_body(content, filename:, operations:, map:, boundary:)

      response = connection.post('/metadata') do |req|
        req.headers['Authorization'] = "Bearer #{ENV['TWENTY_CRM_API_KEY']}" # rubocop:disable Style/FetchEnvVar
        req.headers['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
        req.body = body
        req.options.timeout = 30
        req.options.open_timeout = 10
      end

      if response.status >= 400
        body_preview = response.body.to_s.truncate(200)
        raise UploadError, "Twenty CRM file upload failed (HTTP #{response.status}): #{body_preview}"
      end

      data = JSON.parse(response.body)
      file_id = data.dig('data', 'uploadFilesFieldFile', 'id')

      unless file_id
        raise UploadError,
              "Twenty CRM file upload returned no file ID: #{response.body.to_s.truncate(200)}"
      end

      file_id
    end

    def create_attachment(file_id:, label:, company_id:)
      body = {
        name: label,
        targetCompanyId: company_id,
        file: [{ fileId: file_id, label: label }]
      }

      response = connection.post('/rest/attachments') do |req|
        req.headers['Authorization'] = "Bearer #{ENV['TWENTY_CRM_API_KEY']}" # rubocop:disable Style/FetchEnvVar
        req.headers['Content-Type'] = 'application/json'
        req.body = body.to_json
        req.options.timeout = 10
        req.options.open_timeout = 5
      end

      if response.status >= 400
        body_preview = response.body.to_s.truncate(200)
        raise UploadError, "Twenty CRM attachment creation failed (HTTP #{response.status}): #{body_preview}"
      end

      data = JSON.parse(response.body)
      data.dig('data', 'createAttachment', 'id') || data['id']
    end

    def build_graphql_multipart_body(content, filename:, operations:, map:, boundary:)
      parts = []

      parts << "--#{boundary}\r\n"
      parts << "Content-Disposition: form-data; name=\"operations\"\r\n\r\n"
      parts << operations
      parts << "\r\n"

      parts << "--#{boundary}\r\n"
      parts << "Content-Disposition: form-data; name=\"map\"\r\n\r\n"
      parts << map
      parts << "\r\n"

      parts << "--#{boundary}\r\n"
      parts << "Content-Disposition: form-data; name=\"0\"; filename=\"#{filename}\"\r\n"
      parts << "Content-Type: application/pdf\r\n\r\n"
      parts << content
      parts << "\r\n"

      parts << "--#{boundary}--\r\n"

      parts.join
    end

    def connection
      Faraday.new(url: ENV['TWENTY_CRM_URL']) do |f| # rubocop:disable Style/FetchEnvVar
        f.adapter Faraday.default_adapter
      end
    end
  end
end
