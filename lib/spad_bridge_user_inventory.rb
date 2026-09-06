# frozen_string_literal: true

class SpadBridgeUserInventory
  PAGE_SIZE = 500
  LIFETIME = 10.minutes

  def self.page(admin_id:, snapshot_id: nil, offset: 0)
    if snapshot_id
      if !snapshot_id.is_a?(String) || !snapshot_id.match?(/\A[0-9a-f]{32}\z/)
        raise Discourse::InvalidParameters.new(:snapshot_id)
      end
      snapshot = Discourse.cache.read(cache_key(admin_id, snapshot_id))
      if !snapshot || snapshot[:expires_at] <= Time.now.to_f
        raise Discourse::NotFound
      end
    else
      raise Discourse::InvalidParameters.new(:offset) if offset != 0
      snapshot_id = SecureRandom.hex(16)
      snapshot = capture
      Discourse.cache.write(
        cache_key(admin_id, snapshot_id),
        snapshot,
        expires_in: LIFETIME
      )
    end

    total = snapshot[:users].length
    if offset < 0 || offset > total || offset % PAGE_SIZE != 0
      raise Discourse::InvalidParameters.new(:offset)
    end
    users = snapshot[:users].slice(offset, PAGE_SIZE)
    next_offset = offset + users.length
    complete = next_offset == total
    {
      schema_version: 2,
      snapshot_id: snapshot_id,
      captured_at: snapshot[:captured_at],
      total: total,
      offset: offset,
      page_size: PAGE_SIZE,
      next_offset: complete ? nil : next_offset,
      complete: complete,
      users: users
    }
  end

  def self.capture
    # One SELECT gives the whole identity inventory one database snapshot, including
    # accounts without Discord associations so their usernames remain occupied.
    discord_id = Arel.sql(<<~SQL)
      (SELECT provider_uid FROM user_associated_accounts
       WHERE user_associated_accounts.user_id = users.id AND provider_name = 'discord')
    SQL
    group_ids = Arel.sql(<<~SQL)
      ARRAY(SELECT group_id FROM group_users WHERE group_users.user_id = users.id ORDER BY group_id)
    SQL
    rows =
      User.order(:id).pluck(
        :id,
        :username,
        :active,
        :approved,
        :staged,
        discord_id,
        group_ids
      )
    users =
      rows.map do |id, username, active, approved, staged, provider_uid, memberships|
        {
          id: id,
          username: username,
          active: active,
          approved: approved,
          staged: staged,
          discord_id: provider_uid,
          group_ids: memberships
        }
      end
    {
      captured_at: Time.now.utc.iso8601(6),
      expires_at: Time.now.to_f + LIFETIME,
      users: users
    }
  end

  def self.cache_key(admin_id, snapshot_id)
    "spad-bridge-user-inventory-v2:#{admin_id}:#{snapshot_id}"
  end

  private_class_method :capture, :cache_key
end
