module Koudoku::Subscription
  extend ActiveSupport::Concern

  included do

    # We don't store these one-time use tokens, but this is what Stripe provides
    # client-side after storing the credit card information.
    attr_accessor :credit_card_token

    belongs_to :plan, optional: true

    # update details.
    before_save :processing!
    def processing!

      # if their package level has changed ..
      if changing_plans?

        prepare_for_plan_change

        # and a customer exists in stripe ..
        if stripe_id.present?

          # fetch the customer.
          customer = Stripe::Customer.retrieve(self.stripe_id)

          # if a new plan has been selected
          if self.plan.present?

            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_downgrade if downgrading?
            prepare_for_upgrade if upgrading?

            # update the package level with stripe.
            if self.stripe_subscription_id
              Stripe::Subscription.update(self.stripe_subscription_id, {
                plan: self.plan.stripe_id,
                quantity: team.subscription_quantity,
                proration_behavior: "none",
              })
            else
              subscription = create_subscription(customer)
              self.stripe_subscription_id = subscription.id
            end

            finalize_downgrade! if downgrading?
            finalize_upgrade! if upgrading?

          # if no plan has been selected.
          else

            prepare_for_cancelation

            # Remove the current pricing.
            self.current_price = nil

            # delete the subscription.
            subscription = Stripe::Subscription.retrieve(self.stripe_subscription_id)
            subscription.delete #might break in stripe gem v7 https://github.com/stripe/stripe-ruby/blob/master/CHANGELOG.md#700---2022-08-02
            self.stripe_subscription_id = nil

            finalize_cancelation!

          end

        # when customer DOES NOT exist in stripe ..
        else
          # if a new plan has been selected
          if self.plan.present?

            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_new_subscription
            prepare_for_upgrade

            begin
              raise Koudoku::NilCardToken, "No card token received. Check for JavaScript errors breaking Stripe.js on the previous page." unless credit_card_token.present?

              customer_attributes = {
                description: subscription_owner_description,
                email: subscription_owner_email,
                card: credit_card_token, # obtained with Stripe.js
                metadata: subscription_owner_metadata
              }

              # If the class we're being included in supports Rewardful ..
              if respond_to? :rewardful_id
                if rewardful_id.present?
                  customer_attributes[:metadata] = {referral: rewardful_id}
                end
              end

              # If the class we're being included in supports coupons ..
              if respond_to? :coupon
                if coupon.present? and coupon.free_trial?
                  customer_attributes[:trial_end] = coupon.free_trial_ends.to_i
                end
              end

              customer_attributes[:coupon] = @coupon_code if @coupon_code

              # create a customer at that package level.
              customer = Stripe::Customer.create(customer_attributes)

              finalize_new_customer!(customer.id, plan.price)

              subscription = create_subscription(customer)
              self.stripe_subscription_id = subscription.id

            rescue Stripe::CardError => card_error
              errors[:base] << card_error.message
              card_was_declined
              throw :abort
            end

            # store the customer id.
            self.stripe_id = customer.id
            self.last_four = customer.sources.retrieve(customer.default_source).last4

            finalize_new_subscription!
            finalize_upgrade!

          else

            # This should never happen.

            self.plan_id = nil

            # Remove any plan pricing.
            self.current_price = nil

          end

        end

        finalize_plan_change!

      # if they're updating their credit card details.
      elsif self.credit_card_token.present?

        prepare_for_card_update

        # fetch the customer.
        customer = Stripe::Customer.retrieve(self.stripe_id)
        customer.source = self.credit_card_token
        customer.save #might break in Stripe gem v8 https://github.com/stripe/stripe-ruby/wiki/Migration-guide-for-v8

        # update the last four based on this new card.
        self.last_four = customer.sources.retrieve(customer.default_source).last4
        finalize_card_update!

      end
    end
  end


  def describe_difference(plan_to_describe)
    if plan.nil?
      if persisted?
        I18n.t('koudoku.plan_difference.upgrade')
      else
        if Koudoku.free_trial?
          I18n.t('koudoku.plan_difference.start_trial')
        else
          I18n.t('koudoku.plan_difference.upgrade')
        end
      end
    else
      if plan_to_describe.is_upgrade_from?(plan)
        I18n.t('koudoku.plan_difference.upgrade')
      else
        I18n.t('koudoku.plan_difference.downgrade')
      end
    end
  end

  # Set a Stripe coupon code that will be used when a new Stripe customer (a.k.a. Koudoku subscription)
  # is created
  def coupon_code=(new_code)
    @coupon_code = new_code
  end

  # Pretty sure this wouldn't conflict with anything someone would put in their model
  def subscription_owner
    # Return whatever we belong to.
    # If this object doesn't respond to 'name', please update owner_description.
    send Koudoku.subscriptions_owned_by
  end

  def subscription_owner=(owner)
    # e.g. @subscription.user = @owner
    send Koudoku.owner_assignment_sym, owner
  end

  def subscription_owner_description
    # assuming owner responds to name.
    # we should check for whether it responds to this or not.
    "#{subscription_owner.try(:billing_name) || subscription_owner.try(:name) || subscription_owner.try(:id)}"
  end

  def subscription_owner_email
    "#{subscription_owner.try(:formatted_email_address) || subscription_owner.try(:email)}"
  end

  def subscription_owner_metadata
    subscription_owner.try(:stripe_metadata) || {}
  end

  def subscription_owner_quantity
    subscription_owner.try(:subscription_quantity) || 1
  end

  def changing_plans?
    plan_id_changed?
  end

  def downgrading?
    plan.present? and plan_id_was.present? and plan_id_was > self.plan_id
  end

  def upgrading?
    (plan_id_was.present? and plan_id_was < plan_id) or plan_id_was.nil?
  end

  # Template methods.
  def prepare_for_plan_change
  end

  def prepare_for_new_subscription
  end

  def prepare_for_upgrade
  end

  def prepare_for_downgrade
  end

  def prepare_for_cancelation
  end

  def prepare_for_card_update
  end

  def finalize_plan_change!
  end

  def finalize_new_subscription!
  end

  def finalize_new_customer!(customer_id, amount)
  end

  def finalize_upgrade!
  end

  def finalize_downgrade!
  end

  def finalize_cancelation!
  end

  def finalize_card_update!
  end

  def card_was_declined
  end

  # stripe web-hook callbacks.
  def payment_succeeded(amount)
  end

  def charge_failed
  end

  def charge_disputed
  end

  def create_subscription(customer)
    subscription_attributes = {
      customer: customer.id,
      items:[
        {
          plan: plan.stripe_id,
          quantity: subscription_owner_quantity,
        }
      ],
      trial_from_plan: true,
    }

    # If the class we're being included in supports Link Mink ..
    if respond_to? :link_mink_id
      if link_mink_id.present?
        subscription_attributes[:metadata] = {identifier: link_mink_id}
      end
    end

    Stripe::Subscription.create(subscription_attributes)
  end

end
