# frozen_string_literal: true

require 'rails_helper'

describe 'Start form' do
  let(:account) { create(:account) }
  let(:team) { create(:team, account:) }
  let(:author) { create(:user, account:, team:) }
  let(:editor) { create(:user, account:, team:, role: User::EDITOR_ROLE) }
  let(:other_team_editor) { create(:user, account:, role: User::EDITOR_ROLE) }
  let(:template) { create(:template, account:, author:) }

  before do
    template.update!(team:, shared_link: true)
  end

  describe 'PUT /d/:slug' do
    it 'assigns the template team to the public link submission and submitter' do
      put start_form_path(slug: template.slug), params: { submitter: { email: 'signer@example.com' } }

      submission = template.submissions.last

      expect(response).to redirect_to(submit_form_path(submission.submitters.first.slug))
      expect(submission.team_id).to eq(team.id)
      expect(submission.submitters.map(&:team_id)).to all(eq(team.id))
    end

    it 'makes the public link submission visible to editors of the template team only' do
      put start_form_path(slug: template.slug), params: { submitter: { email: 'signer@example.com' } }

      submission = template.submissions.last

      expect(Submission.accessible_by(Ability.new(editor))).to include(submission)
      expect(Submitter.accessible_by(Ability.new(editor))).to include(submission.submitters.first)
      expect(Submission.accessible_by(Ability.new(other_team_editor))).not_to include(submission)
    end
  end
end
