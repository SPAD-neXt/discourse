# frozen_string_literal: true

RSpec.describe Admin::SpadBridgeUsersController do
  fab!(:admin)
  fab!(:user)
  fab!(:moderator)

  describe "#index" do
    let(:path) { "/admin/spad-bridge/users.json" }
    let(:headers) do
      { "Api-Key" => Fabricate(:api_key, user: admin).key, "Api-Username" => admin.username }
    end

    it "rejects anonymous requests" do
      get path
      expect(response.status).to eq(404)
    end

    it "rejects browser admin sessions" do
      sign_in(admin)
      get path
      expect(response.status).to eq(403)
    end

    it "rejects ordinary and moderator API identities" do
      [user, moderator].each do |identity|
        key = Fabricate(:api_key, user: identity)
        get path, headers: { "Api-Key" => key.key, "Api-Username" => identity.username }
        expect(response.status).to eq(404)
      end
    end

    it "returns Discord IDs as strings and includes usernames of unlinked users without emails" do
      UserAssociatedAccount.create!(
        user: user,
        provider_name: "discord",
        provider_uid: "123456789012345678",
      )
      get path, headers: headers
      expect(response.status).to eq(200)
      body = response.parsed_body
      expect(body).to include(
        "schema_version" => 1,
        "offset" => 0,
        "complete" => true,
        "next_offset" => nil,
      )
      expect(body["total"]).to eq(User.count)
      expect(body["users"].find { |row| row["id"] == user.id }).to include(
        "discord_id" => "123456789012345678",
        "username" => user.username,
      )
      expect(body["users"].find { |row| row["id"] == admin.id }).to include("discord_id" => nil)
      expect(body["users"].flat_map(&:keys).uniq).to contain_exactly(
        "id",
        "username",
        "active",
        "approved",
        "staged",
        "discord_id",
      )
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "keeps pages stable when users and associations change after capture" do
      stub_const(SpadBridgeUserInventory, :PAGE_SIZE, 2) do
        UserAssociatedAccount.create!(
          user: user,
          provider_name: "discord",
          provider_uid: "123456789012345678",
        )
        get path, headers: headers
        first = response.parsed_body
        original_ids = User.order(:id).pluck(:id)
        UserAssociatedAccount.where(user: user).update_all(provider_uid: "123456789012345679")
        Fabricate(:user)
        rows = first["users"]
        page = first
        until page["complete"]
          get path,
              params: {
                snapshot_id: first["snapshot_id"],
                offset: page["next_offset"],
              },
              headers: headers
          expect(response.status).to eq(200)
          page = response.parsed_body
          expect(page.values_at("snapshot_id", "captured_at", "total")).to eq(
            first.values_at("snapshot_id", "captured_at", "total"),
          )
          rows.concat(page["users"])
        end
        expect(rows.map { |row| row["id"] }).to eq(original_ids)
        expect(rows.find { |row| row["id"] == user.id }["discord_id"]).to eq("123456789012345678")
      end
    end

    it "rejects expired snapshots instead of returning an empty inventory" do
      get path, headers: headers
      snapshot_id = response.parsed_body["snapshot_id"]
      freeze_time(11.minutes.from_now)
      get path, params: { snapshot_id: snapshot_id }, headers: headers
      expect(response.status).to eq(404)
    end

    it "does not share snapshots between administrators" do
      get path, headers: headers
      snapshot_id = response.parsed_body["snapshot_id"]
      other = Fabricate(:admin)
      key = Fabricate(:api_key, user: other)
      get path,
          params: {
            snapshot_id: snapshot_id,
          },
          headers: {
            "Api-Key" => key.key,
            "Api-Username" => other.username,
          }
      expect(response.status).to eq(404)
    end

    it "rejects invalid cursors" do
      [
        { offset: "-1" },
        { offset: "1" },
        { offset: "1x" },
        { snapshot_id: "invalid" },
      ].each do |params|
        get path, params: params, headers: headers
        expect(response.status).to eq(400)
      end
    end
  end
end
