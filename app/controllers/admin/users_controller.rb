# frozen_string_literal: true

module Admin
  class UsersController < Admin::ApplicationController
    def index
      scope = User.all
      scope = scope.where(type: params[:type]) if params[:type].present?
      scope = scope.where(state: params[:state]) if params[:state].present?
      field = params[:field] || "login"

      if params[:q].present?
        qstr = "%#{params[:q].downcase}%"
        scope = begin
          case params[:field]
          when "login"
            scope.where("lower(login) LIKE ?", qstr)
          when "email"
            scope.where("lower(email) LIKE ?", qstr)
          when "name"
            scope.where("lower(name) LIKE ?", qstr)
          end
        end
      end

      @users = scope.order(id: :desc).page(params[:page])
    end

    def show
      @user = User.find(params[:id])
    end

    def new
      @user = User.new
      @user._id = nil
    end

    def edit
      @user = User.find(params[:id])
    end

    def create
      @user = User.new(params[:user].permit!)
      @user.email = params[:user][:email]
      @user.login = params[:user][:login]
      @user.state = params[:user][:state]

      if @user.save
        redirect_to(admin_users_path, notice: "User was successfully created.")
      else
        render action: "new"
      end
    end

    def update
      @user = User.find_by_login!(params[:id])
      type = @user.user_type # Can be :team or :user

      @user.email = params[type][:email]
      @user.login = params[type][:login]
      @user.state = params[type][:state] if params[type][:state] # Avoid `ActiveRecord::NotNullViolation` exception for Team entity.

      if @user.update(params[type].permit!)
        redirect_to(edit_admin_user_path(@user.id), notice: "User was successfully updated.")
      else
        render action: "edit"
      end
    end

    def destroy
      @user = User.find(params[:id])
      if @user.user_type == :user
        @user.soft_delete
      else
        unless @user.team_profile.blank?
          @user.team_profile.destroy
        end

        unless @user.team_users.blank?
          @user.team_users.each { |t| t.destroy }
        end
        @user.destroy
      end

      redirect_to(admin_users_url)
    end

    def clean
      @user = User.find_by_login!(params[:id])
      case params[:type]
      when "replies"
        _clean_replies
      when "topics"
        _clean_topics
      end
    end

    def _clean_replies
      # 为了避免误操作删除大量，限制一次清理 10 条，这个数字对刷垃圾回复的够用了。
      ids = Reply.unscoped.where(user_id: @user.id).recent.limit(10).pluck(:id)
      replies = Reply.unscoped.where(id: ids)
      topics = Topic.where(id: replies.collect(&:topic_id))
      replies.delete_all
      topics.each(&:touch)

      count = Reply.unscoped.where(user_id: @user.id).count
      redirect_to edit_admin_user_path(@user.id), notice: "最近 10 条删除，成功 #{@user.login} 还有 #{count} 条回帖。"
    end

    def _clean_topics
      Topic.unscoped.where(user_id: @user.id).recent.limit(10).delete_all
      redirect_to edit_admin_user_path(@user.id), notice: "最近 10 条删除成功。"
    end

    def edit_assign_nodes
      @user = User.find(params[:id])
    end

    def assign_nodes
      ids = params[:node_ids]
      ids = Node.ids & ids.map(&:to_i)
      @user = User.find(params[:id])

      if @user.maintainer?
        @user.update(node_assignment_ids: ids)
        flash[:notice] = "分配成功"
        render json: { msg: "分配成功" }
      else
        render json: { msg: "只有版主才能分配节点" }, status: 403
      end
    end

    def send_sms
      message = params[:message]
      if message.blank?
        redirect_to(admin_users_url, notice: "空消息不处理！")
      end

      type = "#{params[:type].downcase}"
      uids = []
      if type == "all"
        users = User.all
        uids = users.ids
      else
        q = params[:login_name]
        login_names = q.split(",")
        if login_names.blank?
          redirect_to(admin_users_url, notice: "选择个人时候，请输入用户登录名！")
        end

        login_names.each do |name|
          u = User.find_by_login!(name)
          uids << u.try(:id)
        end
      end

      if uids.blank?
        redirect_to(admin_users_url, notice: "没有用户，不发送！")
      end
      # 给所有用户发通知
      default_note = { notify_type: "admin_sms", target_type: "User", actor_id: current_user.id }
      Notification.bulk_insert(set_size: 100) do |worker|
        uids.each do |uid|
          note = default_note.merge({ user_id: uid, target_id: uid, message: message })
          worker.add(note)
        end
      end

      redirect_to(admin_users_url, notice: "发送完毕！")
    end
  end
end
