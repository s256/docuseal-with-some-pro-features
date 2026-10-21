# frozen_string_literal: true

require 'rails_helper'

describe 'Start form' do
  let(:account) { create(:account) }
  let(:team) { create(:team, account:, name: 'Signing Team') }
  let(:author) { create(:user, account:, team:) }
  let(:editor) { create(:user, account:, team:, role: User::EDITOR_ROLE) }
  let(:other_team_editor) do
    create(:user, account:, team: create(:team, account:, name: 'Other Team'), role: User::EDITOR_ROLE)
  end
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

    context 'when the second party has a preset email' do
      let(:template) { create(:template, submitter_count: 2, account:, author:) }

      before do
        template.update!(submitters: [template.submitters.first,
                                      template.submitters.second.merge('email' => 'preset@example.com')])
      end

      it 'assigns the template team to all submitters' do
        put start_form_path(slug: template.slug), params: { submitter: { email: 'signer@example.com' } }

        submission = template.submissions.last

        expect(submission.submitters.map(&:email)).to contain_exactly('signer@example.com', 'preset@example.com')
        expect(submission.submitters.map(&:team_id)).to all(eq(team.id))
        expect(Submitter.accessible_by(Ability.new(editor))).to include(*submission.submitters)
      end
    end
  end
end
