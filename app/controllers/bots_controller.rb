module Ember
  module Admin
    class BotsController < ApiApplicationController
      include HelperConcern

      def index
        @bots = {
          onboarded: bot_onboarded?
        }
        load_products
        @bots
      end

      def new
        return unless validate_query_params
        return unless validate_delegator(nil, delegator_hash)
        @bot = {
          product: product_hash(@portal)
        }
        profile_settings = Bot.default_profile
        @bot = @bot.merge(profile_settings)
        @bot
      end

      def create
        return unless validate_body_params(@item)
        return unless validate_delegator(@item, delegator_hash)
        construct_attributes
        create_bot
      end

      def show
        return unless validate_query_params
        @bot = {
          product: product_hash(@item.portal),
          id: params[:id].to_i,
          external_id: @item.external_id,
          enable_on_portal: @item.enable_in_portal
        }
        training_status = @item.training_status
        @bot.merge!{ status: training_status } if training_status
        @bot.merge!(@item.profile)
        @bot
      end

      def update
        return unless validate_query_params(@item)
        return unless validate_delegator(nil, params.merge(support_bot: @item))
        @item = update_bot_attribute @item
        update_bot
      end

      private

        def construct_attributes
          @item.external_id = generate_uuid
          @item.last_updated_by = current_user.id
          product = @portal.product
          @item.product_id = product.id if product
          @item.additional_settings = {}
          @avatar = params['avatar']
          if @avatar && @avatar['is_default']
            ## Additional settings column contains info about default avatar
            ##Custom avatar data will be taken from attachment table
            @item.additional_settings = {
              is_default: true,
              avatar_id: @avatar['avatar_id']
            }
          elsif @avatar && !@avatar['is_default']
            @item.additional_settings = {
              is_default: false
            }      
          end
          @item
        end

        def create_bot
          response, response_code = Freshbots::Bot.create_bot(@item, @avatar)
          unless response_code == Freshbots::Bot::BOT_CREATION_SUCCESS_STATUS
            raise "error in creating bot at BOT-SIDE @@response -> #{response}"
          end
          @item.additional_settings.merge!(
            bot_hash: response['content']['botHsh']
          )
          if save_bot
            @bot = {
              id: @item.id
            }
            @bot
          else
            render_errors(@item.errors)
          end
        rescue Exception => e
          Rails.logger.error "#{e.inspect}------ @@bot_hash -> #{@item.additional_settings[:bot_hash]}--@@external_id -> #{@item.external_id},,,@@account_id -> #{current_account.id}"
          Rails.logger.error e.backtrace.join("\n")
          render_base_error(:internal_error, 500)
        end

        def update_bot
          response, response_code = Freshbots::Bot.update_bot(@item, @avatar)
          unless response_code == Freshbots::Bot::BOT_UPDATION_SUCCESS_STATUS
            raise "error in updating at BOT-SIDE @@response -> #{response}"
          end
          if save_bot
            head 204
          else
            render_errors(@item.errors)
          end
        rescue Exception => e
          Rails.logger.error "#{e.inspect}---- @@bot_hash -> #{@item.additional_settings[:bot_hash]} -- @@bot_id -> #{@item.id}-- @@external_id -> #{@item.external_id}-- @@account_id -> #{current_account.id}"
          Rails.logger.error e.backtrace.join("\n")
          render_base_error(:internal_error, 500)
        end

        def get_portal_logo_url(portal)
          logo = portal.logo
          logo_url = logo.content.url if logo.present?
          logo_url
        end

        def product_hash(portal)
          name = portal.main_portal? ? portal.name : portal.product.name
          {
            name: name,
            portal_id: portal.id,
            portal_logo: get_portal_logo_url(portal)
          }
        end

        def load_products
          products_details = []
          portal = current_account.main_portal
          logo_url = get_portal_logo_url(portal)
          bot = portal.bot
          if bot
            bot_name = bot.name
            bot_id = bot.id
          end
          products_details << { name: portal.name, portal_enabled: true, portal_id: portal.id, portal_logo: logo_url, bot_name: bot_name, bot_id: bot_id }
          products = fetch_products
          products.each do |product|
            products_details << product.bot_info
          end
          @bots[:products] = products_details
          @bots
        end

        def delegator_hash
          @portal = get_portal(params[:portal_id])
          bot = @portal.bot if @portal
          delegator_hash = params.merge(portal: @portal, support_bot: bot)
          delegator_hash
        end

        def feature_name
          FeatureConstants::BOT
        end

        def scoper
          current_account.bots
        end

        def constants_class
          'BotConstants'.freeze
        end

        def fetch_products
          current_account.products.preload({ portal: :logo }, :bot)
        end

        def bot_onboarded?
          Account.current.bots.exists?
        end

        def generate_uuid
          UUIDTools::UUID.timestamp_create.hexdigest
        end

        def get_portal(portal_id)
          current_account.portals.where(id: portal_id).first
        end

        def build_object
          account_included = scoper.attribute_names.include?('account_id')
          build_params  = account_included ? { account: current_account } : {}
          build_params  = build_params.merge(
            template_data: {
              header: params['header'],
              theme_colour: params['theme_colour'],
              widget_size: params['widget_size']
            },
            name: params['name'],
            portal_id: params['portal_id']
          )
          @item = scoper.new(build_params)
          @item
        end

        def update_bot_attribute(bot)
          bot.name = params['name'] if params['name']
          [:header, :theme_colour, :widget_size].each do |attr|
            bot.template_data[attr] = params[attr] if params[attr]
          end
          bot.last_updated_by = current_user.id
          @avatar = params['avatar']
          return bot unless @avatar
          if @avatar['is_default'] == true ||
             (@avatar['is_default'].nil? && bot.additional_settings[:is_default])
             bot.additional_settings[:is_default] = !!@avatar['is_default']
             bot.additional_settings[:avatar_id] = @avatar['avatar_id']
          else
            bot.additional_settings[:is_default] = false
            bot.additional_settings.delete(:avatar_id)
          end
          bot
        end

        def save_bot
          if @avatar && !@item.additional_settings[:is_default]
            logo = current_account.attachments.where(id: @avatar['avatar_id']).first if @avatar['avatar_id'].present?
            @item.logo.delete if @item.logo
            @item.logo = logo
          end
          @item.save
        end
    end
  end
end
