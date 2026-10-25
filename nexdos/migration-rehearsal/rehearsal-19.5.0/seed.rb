# Seeds the "before" (sameersbn) instance with data that exercises everything the clone has
# to carry over: users, a group + project with a real commit, an issue, an encrypted CI
# variable (proves secrets are carried), and the things SANITIZE must switch off - a
# webhook, a pipeline schedule, an enabled cleanup policy. Idempotent-ish: run once.
#
# docker exec -i -u git -e HOME=/home/git -w /home/git/gitlab nxreh195-gitlab \
#   bundle exec rails runner -e production - < seed.rb

root = User.find_by_username!('root')
org = Organizations::Organization.default_organization rescue nil

alice = User.find_by_username('alice') || Users::CreateService.new(root,
  username: 'alice', name: 'Alice Rehearsal', email: 'alice@rehearsal.local',
  password: 'Qz8vWn3kLp7Rt2Ym', password_confirmation: 'Qz8vWn3kLp7Rt2Ym',
  skip_confirmation: true, organization_id: org&.id).execute.payload[:user]
puts "user: #{alice.username} (#{alice.id})"

group = Group.find_by_full_path('dagster') || Groups::CreateService.new(root,
  name: 'dagster', path: 'dagster', organization_id: org&.id).execute.payload[:group]
group.add_owner(root)
group.add_developer(alice)
puts "group: #{group.full_path}"

project = Project.find_by_full_path('dagster/pipeline') || Projects::CreateService.new(root,
  name: 'pipeline', path: 'pipeline', namespace_id: group.id,
  initialize_with_readme: true, organization_id: org&.id).execute
raise "project not created: #{project.errors.full_messages}" unless project.persisted?
puts "project: #{project.full_path}, commit: #{project.repository.commit&.short_id}"

Issues::CreateService.new(container: project, current_user: root,
  params: { title: 'Rehearsal issue', description: 'carried over?' }).execute
project.variables.find_or_create_by!(key: 'REHEARSAL_SECRET') { |v| v.value = 'decrypt-me-42' }
project.hooks.create!(url: 'http://example.invalid/hook', push_events: true) unless project.hooks.exists?
Ci::PipelineSchedule.find_or_create_by!(project: project, description: 'nightly') do |s|
  s.cron = '0 1 * * *'; s.cron_timezone = 'UTC'; s.ref = 'refs/heads/main'
  s.owner = root; s.active = true
end
project.container_expiration_policy.update!(enabled: true, keep_n: 1, older_than: '7d',
                                            name_regex: '.*', cadence: '1d')

puts "issues: #{project.issues.count}, ci var: #{project.variables.find_by(key: 'REHEARSAL_SECRET').value}"
puts "hooks: #{project.hooks.count}, schedules: #{project.pipeline_schedules.where(active: true).count}, " \
     "cleanup policy enabled: #{project.container_expiration_policy.enabled}"
