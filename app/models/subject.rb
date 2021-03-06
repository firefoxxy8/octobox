class Subject < ApplicationRecord
  has_many :notifications, foreign_key: :subject_url, primary_key: :url
  has_many :labels, dependent: :delete_all
  has_many :users, through: :notifications

  BOT_AUTHOR_REGEX = /\A(.*)\[bot\]\z/.freeze
  private_constant :BOT_AUTHOR_REGEX

  scope :label, ->(label_name) { joins(:labels).where(Label.arel_table[:name].matches(label_name)) }
  scope :repository, ->(full_name) { where(arel_table[:url].matches("%/repos/#{full_name}/%")) }

  after_update :sync_involved_users

  def author_url
    "#{Octobox.config.github_domain}#{author_url_path}"
  end

  def update_labels(remote_labels)
    existing_labels = labels.to_a
    remote_labels.each do |l|
      label = labels.find_by_github_id(l['id'])
      if label.nil?
        labels.create({
          github_id: l['id'],
          color: l['color'],
          name: l['name'],
        })
      else
        label.github_id = l['id'] # smoothly migrate legacy labels
        label.color = l['color']
        label.name = l['name']
        label.save if label.changed?
      end
    end

    remote_label_ids = remote_labels.map{|l| l['id'] }
    deleted_labels = existing_labels.reject{|l| remote_label_ids.include?(l.github_id) }
    deleted_labels.each(&:destroy)
  end

  def sync_involved_users
    return unless Octobox.github_app?
    user_ids.each do |user_id|
      SyncNotificationsWorker.perform_async_if_configured(user_id)
    end
  end

  def self.sync(remote_subject)
    subject = Subject.find_or_create_by(url: remote_subject['url'])
    subject.update({
      github_id: remote_subject['id'],
      state: remote_subject['merged_at'].present? ? 'merged' : remote_subject['state'],
      author: remote_subject['user']['login'],
      html_url: remote_subject['html_url'],
      created_at: remote_subject['created_at'],
      updated_at: remote_subject['updated_at'],
      assignees: ":#{Array(remote_subject['assignees'].try(:map) {|a| a['login'] }).join(':')}:"
    })
    subject.update_labels(remote_subject['labels']) if remote_subject['labels'].present?
    subject.sync_involved_users
  end

  private

  def author_url_path
    if bot_author?
      "/apps/#{BOT_AUTHOR_REGEX.match(author)[1]}"
    else
      "/#{author}"
    end
  end

  def bot_author?
    BOT_AUTHOR_REGEX.match?(author)
  end
end
