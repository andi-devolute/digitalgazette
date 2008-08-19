#
# SocialUser
# ====================================
#
# A SocialUser is a user that socializes. I bet you didn't see that coming.
#
# What does it mean to be social?
# 
# (1) you have a relationship to other users, friend and foe.
# (2) you have a relationship to groups, and to the group's
#     committees, networks and members.
# (3) you have a set of tags used in all these places.
#
# In crabgrass, all users are SocialUsers, but this stuff is kept here
# to try to make User.rb more readable.
#
# In short, any model stuff related to group memberships and user to user
# relations should go here.
#
#
# Columns
# --------
#
# version -- increments when any of the id caches are changed
# 
# id caches -- there are many columns to cache our relationships,
#   because they are used very frequently and take time to calculate.
#   The names of the cache attributes end with "_cache". 
#
# How to use
# -----------
# 
# There are two valid ways to establish membership between user and group:
#
# group.memberships.create :user => user
# user.memberships.create :group => group
#
# Other methods should not be used.
#
# Membership information is cached in the user table. It will get
# automatically updated whenever membership is created or destroyed. In cases
# of indirect membership (all_groups) the database is correctly updated
# but the in-memory object will need to be reloaded if you want the new data.
#
# However, when the structure of an organization changes (via adding/removing
# networks or committees), then the cache is not automatically updated. 
# In these cases, you need to manually clear the cache and reload the user. 
#

module SocialUser

  def self.included(base) #nodoc#
    base.instance_eval do
      include CacheColumns
      include Groups, Tags, Contacts, Peers, Caching, Pages
    end
  end

   
  ######################################################################
  ## Relationship to groups
  module Groups

    def self.included(base)

      base.instance_eval do
        has_many :memberships, :foreign_key => 'user_id',
          :dependent => :destroy,
          :before_add => :check_duplicate_memberships,
          :after_add => [:update_membership_cache, :clear_peer_cache_of_my_peers],
          :after_remove => [:clear_peer_cache_of_my_peers, :update_membership_cache]
        
        has_many :groups, :foreign_key => 'user_id', :through => :memberships do
          def <<(*dummy)
            raise Exception.new("don't call << on user.groups");
          end
          def delete(*records)
            super(*records)
            proxy_owner.clear_peer_cache_of_my_peers
            proxy_owner.update_membership_cache
          end
        end
          
        # all groups, including groups we have indirect access to (ie committees and networks)
        has_many :all_groups, :class_name => 'Group', 
          :finder_sql => 'SELECT groups.* FROM groups WHERE groups.id IN (#{all_group_id_cache.to_sql})'
        
        serialize_as IntArray, :direct_group_id_cache, :all_group_id_cache, :peer_id_cache

        initialized_by :update_membership_cache,
          :direct_group_id_cache, :all_group_id_cache, :peer_id_cache


        #this seems to be the only way to override the A/R created method
        remove_method :all_group_ids
        remove_method :group_ids
      end
    end

      # alias for the cache.
      def group_ids
        self.direct_group_id_cache
      end
      
      # alias for the cache
      def all_group_ids
        self.all_group_id_cache
      end
        
      # is this user a member of the group?
      # (or any of the associated groups)
      def member_of?(group)
        if group.is_a? Array
          group.detect{|g| member_of?(g)}
        elsif group.is_a? Integer
          all_group_ids.include?(group)
        elsif group.is_a? Group
          all_group_ids.include?(group.id)
        end
      end
      
      # is the user a direct member of the group?
      def direct_member_of?(group)
        if group.is_a? Array
          group.detect{|g| direct_member_of?(g)}
        elsif group.is_a? Integer
          group_ids.include?(group)
        elsif group.is_a? Group
          group_ids.include?(group.id)
        end
      end

      # eventually, we will have group admins.
      # for now, we can just make this return true
      # for all members
      def may_admin?(group)
        member_of?(group)
      end
        
      def check_duplicate_memberships(membership)
        raise AssociationError.new('you cannot have duplicate membership') if self.group_ids.include?(membership.group_id)
      end
    #end
  end
    
  ######################################################################
  ## Relationship to other users
  module Contacts

    def self.included(base)
      base.instance_eval do
        serialize_as IntArray, :friend_id_cache, :foe_id_cache

        initialized_by :update_contacts_cache,
          :friend_id_cache, :foe_id_cache
        
        has_and_belongs_to_many :contacts,
          {:class_name => "User",
          :join_table => "contacts",
          :association_foreign_key => "contact_id",
          :foreign_key => "user_id",
          :uniq => true,
          :before_add => :check_duplicate_contacts,
          :after_add => :reciprocate_add,
          :after_remove => :reciprocate_remove} do
          def online
            find( :all, 
              :conditions => ['users.last_seen_at > ?',10.minutes.ago],
              :order => 'users.last_seen_at DESC' )
          end
        end
      end
    end

    def check_duplicate_contacts(other_user)
      raise AssociationError.new('cannot be duplicate contacts') if self.contacts.include?(other_user)
    end
    
    def reciprocate_add(other_user)
      unless other_user.contacts.include?(self)
        other_user.contacts << self 
        update_contacts_cache
      end
    end
    
    def reciprocate_remove(other_user)
      if other_user.contacts.include?(self)
        other_user.contacts.delete(self)
        update_contacts_cache
      end
    end
  end

  # peers are users who share at least one group with us
  module Peers
    def self.included(base)
      base.instance_eval do
        has_many :peers, :class_name => 'User',
          :finder_sql => 'SELECT users.* FROM users WHERE users.id IN (#{peer_id_cache.to_sql})'
      end
    end

    ##
    ## TODO: this is a stub. may_pester?(entity) should return true if self
    ## is able to pester the entity. The entity might be a group or a user.
    ## What does it mean to pester? If true is returned, we assume that self
    ## is able to do things that are potentially annoying to the other
    ## person/group, like invite them to things, send them notices, etc.
    ## 

    def may_be_pestered_by?(user)
      return true
    end

    def may_pester?(entity)
      entity.may_be_pestered_by? self
    end

    def stranger_to?(user)
      !peer_of(user) and !contact_of(user)
    end
    
    def peer_of?(user)
      id = user.instance_of?(Integer) ? user : user.id
      peer_id_cache.include?(id)  
    end
    
    def friend_of?(user)
      id = user.instance_of?(Integer) ? user : user.id
      friend_id_cache.include?(id)
    end
    
    def relationship_to(user)
      relationships_to(user).first
    end
    def relationships_to(user)
      return :stranger unless user
      (@relationships ||= {})[user.login] ||= get_relationships_to(user)
    end
    def get_relationships_to(user)
      ret = []
      ret << :friend   if friend_of?(user)
      ret << :peer     if peer_of?(user)
  #   ret << :fof      if fof_of?(user)
      ret << :stranger if ret.empty?
      ret
    end
  end
    
  ######################################################################
  ## Relationship to tags
  module Tags

    def self.included(base)
      base.instance_eval do
        serialize_as IntArray, :tag_id_cache

        initialized_by :update_tag_cache, :tag_id_cache

        has_many :tags,
          :finder_sql => 'SELECT DISTINCT tags.* FROM tags WHERE tags.id IN ({#{tag_id_cache.to_sql})'
      end
    end
    
  end 

  ######################################################################
  ## Caching IDs
 
  # The idea here is that every user in a social networking universe
  # has a lot of relationships to other entities that might be expensive
  # to discover. For example, a list of all your peers or a list of all
  # groups you have direct or indirect access to. So, we cache it, in
  # the form of serialized arrays of integers corresponding to the ids of the
  # foreign relationships.

  # If you are paying attention, you will realize this is stupid. A couple reasons
  # why it is not:

  #   (1) by using compressed integers for serialization, we can actually store
  #       a lot of ids without taking up too much space.
  #   (2) it is much faster to deserialize a big array of integers than it is
  #       to join in another table or make an extra query.

  # In many cases, all we *want* are the ids, since this is sufficient
  # to test membership and to display name and avatar (if ever get around
  # to creating a memcached for users and groups that stores [id,name,avatar_id]).

  # Also, we make a lot of queries of the form "group_id IN (1,2,3,4)".
  # This is fast, according to the mysql manual:

  #    If all values are constants, they are evaluated according to
  #    the type of expr and sorted. The search for the item then is
  #    done using a binary search. This means IN is very quick if
  #    the IN value list consists entirely of constants.

  # This suggests that if we stored the ids caches pre-sorted, it would be
  # slightly faster.

  # As a handy bit of fun, if any of these ids caches changes, we increment
  # the user's version. This can be then used to easily expire caches which
  # use these values.
  module Caching


    # Be careful with this method: it is called any time a Membership
    # object is created or destroyed, and it is also called any time
    # read_attribute(*_group_id_cache) is nil. Therefore, we better
    # set the id caches to non-nil in this method unless we want to
    # recurse forever.
    def update_membership_cache(membership=nil)
      direct, all = get_group_ids
      peer = get_peer_ids(direct)
      update_attributes :version => version+1,
        :direct_group_id_cache => direct,
        :all_group_id_cache    => all,
        :peer_id_cache         => peer
    end

    #
    # When our membership changes, we need to clear the peer cache of all
    # the users who might have their peer info change. To do so, this method
    # must be called in two places:
    #   1) after a new membership is created
    #   2) before a membership is destroyed
    #
    def clear_peer_cache_of_my_peers(membership=nil)
      if peer_id_cache.any?
        self.class.connection.execute "UPDATE users SET peer_id_cache = NULL WHERE id IN (#{peer_id_cache.join(',')})"
      end
    end

    # This should be called if a change in relationships has potentially
    # invalidated the cache. For example, adding or removing a commmittee.
    # This only updates the database: if you want to update the in-memory
    # object, follow this call with reload()
    def clear_cache
       self.class.connection.execute "
         UPDATE users SET 
         tag_id_cache = NULL, direct_group_id_cache = NULL, foe_id_cache = NULL,
         peer_id_cache = NULL, friend_id_cache = NULL, all_group_id_cache = NULL
         WHERE id = #{self.id}"
    end
    
    def update_contacts_cache()
      friend,foe = get_contact_ids
      update_attributes :version => version+1,
        :friend_id_cache => friend,
        :foe_id_cache    => foe
    end
      
    # include direct memberships, committees, and networks
    def get_group_ids
      if self.id
        direct = Group.connection.select_values(%Q[
          SELECT groups.id FROM groups
          INNER JOIN memberships ON groups.id = memberships.group_id
          WHERE (memberships.user_id = #{self.id})
        ])
      else
        direct = []
      end
      if direct.any?
        committee = Group.connection.select_values(%Q[
          SELECT groups.id FROM groups
          WHERE groups.parent_id IN (#{direct.join(',')})
        ])
        network = Group.connection.select_values(%Q[
          SELECT groups.id FROM groups
          INNER JOIN federations ON groups.id = federations.network_id
          WHERE federations.group_id IN (#{direct.join(',')})
          AND (groups.type = 'Network')
        ])
      else
        committee, network = [],[]
      end
      direct = direct.collect{|id| id.to_i}.uniq
      all = (direct + committee + network).collect{|id|id.to_i}.uniq
      [direct, all]
    end

    def get_peer_ids(group_ids)
      return [] unless self.id
      User.connection.select_values( %Q[
        SELECT DISTINCT users.id FROM users
        INNER JOIN memberships ON users.id = memberships.user_id
        WHERE users.id != #{id}
        AND memberships.group_id IN (#{ group_ids.any? ? group_ids.join(',') : 'NULL'})
      ])
    end

    def get_contact_ids()
      return [[],[]] unless self.id
      foe = [] # no foes yet.
      friend = Contact.connection.select_values( %Q[
        SELECT contacts.contact_id FROM contacts
        WHERE contacts.user_id = #{self.id}
      ])
      [friend,foe]
    end
    
    def update_tag_cache
      # this query sucks and should be optimized
      # see http://dev.mysql.com/doc/refman/5.0/en/in-subquery-optimization.html
      # TODO: acts_as_taggable_on includes the user_id in every tagging,
      # thus making it easy to find all the tags you have made. maybe this is
      # what we should return here instead?
      if self.id
        ids = Tag.connection.select_values(%Q[
          SELECT tags.id FROM tags
          INNER JOIN taggings ON tags.id = taggings.tag_id
          WHERE taggings.taggable_type = 'Page' AND taggings.taggable_id IN
           (SELECT pages.id FROM pages
            INNER JOIN user_participations ON pages.id = user_participations.page_id
            WHERE user_participations.user_id = #{id})
        ])
      else
        ids = []
      end
      update_attributes :version => version+1, :tag_id_cache => ids
    end

  end

  ############################################################################
  ## RELATIONSHIP TO PAGES
  module Pages
    def self.included(base)
      base.instance_eval do
        has_many :participations, :class_name => 'UserParticipation', 
          :after_add => :update_tag_cache, :after_remove => :update_tag_cache
        has_many :pages, :through => :participations do
          def pending
            find(:all, :conditions => ['resolved = ?',false], :order => 'happens_at' )
          end
        end
        
        has_many :pages_created,
          :class_name => "Page", :foreign_key => :created_by_id 

        has_many :pages_updated, 
          :class_name => "Page", :foreign_key => :updated_by_id   
      end
    end

    def may?(perm, page)
      begin
        return may!(perm,page)
      rescue PermissionDenied
        return false
      end
    end
    
    # basic permissions:
    #   :view or :read -- user can see the page.
    #   :edit or :change -- user can participate.
    #   :admin -- user can destroy the page, change access.
    # conditional permissions:
    #   :comment -- sometimes viewers can comment and sometimes only participates can.
    #
    # this is still a basic stub.
    #
    # :view should only return true if the user has access to view the page
    # because of participation objects, NOT because the page is public.
    #
    def may!(perm, page)
      upart ||= page.participation_for_user(self)
      return true if upart
      gparts = page.participation_for_groups(all_group_ids)
      return true if gparts.any?
      raise PermissionDenied
    end
    
    ##
    ## makes self a participant of a page. 
    ## this method is not called directly. instead, page.add(user)
    ## should be used.
    ##
    ## TODO: delete the user_participation row if it is not really needed
    ## anymore (ie, the user won't lose access by deleted it, and inbox,
    ## watch, star are all false, and the user has not contributed.)
    def add_page(page, part_attrs)
      part_attrs = part_attrs.dup
      part_attrs[:notice] = [part_attrs[:notice]] if part_attrs[:notice]
      participation = page.participation_for_user(self)
      if participation
        self.update_participation(participation, part_attrs)
      else
        self.create_participation(page, part_attrs)
      end  
      page.changed :users
    end
    ## called only by add_page
    def update_participation(participation, part_attrs)
      if part_attrs[:notice]        
        part_attrs[:viewed] = false
        if participation.notice
          if repeat_notice?(participation.notice, part_attrs[:notice])
            part_attrs[:notice] = participation.notice # don't repeat
          else
            part_attrs[:notice] += participation.notice
          end
        end
      end
      participation.update_attributes(part_attrs)
    end
    ## called only by update_participation
    def repeat_notice?(current_notices, new_notice)
      new_notice = new_notice.first
      current_notices.detect do |notice|
        notice[:message] == new_notice[:message] and notice[:user_login] == new_notice[:user_login]
      end
    end
    ## called only by add_page
    def create_participation(page, part_attrs)
      # user_participations.build doesn't update the pages.users
      # until it is saved, so we use create instead
      page.user_participations.create(part_attrs.merge(
        :page_id => page.id, :user_id => id,
        :resolved => page.resolved?))
    end
    
    def remove_page(page)
      page.users.delete(self)
      page.changed :users
    end
    
    # should be called when a user visits a page
    # we only update user_participation if it already exists
    def viewed(page)
      part = page.participation_for_user(self)
      return unless part
      part.update_attributes(:viewed_at => Time.now, :notice => nil, :viewed => true)
    end
    
    # set resolved status vis-à-vis self.
    def resolved(page, resolved_flag)
      find_or_build_participation(page).update_attributes :resolved => resolved_flag
    end
    
    def find_or_build_participation(page)
      page.participation_for_user(self) || page.user_participations.build(:user_id => self.id) 
    end
    
    # TODO: make this not save the page.
    # should be called when a user writes to a page
    # or resolves a page.
    # options:
    #  - resolved: user's participation is resolved with this page
    #  - all_resolved: everyone's participation is resolved.
    #
    def updated(page, options={})
      # create self's participation if it does not exist
      find_or_build_participation(page)

      unless page.contributors.include?(self)
        page.contributors_count +=1
      end
       
      # update everyone's participation
      now = Time.now
      page.user_participations.each do |party|
        if party.user_id == self.id
          party.changed_at = now
          party.viewed_at = now
          party.viewed = true
          party.resolved = options[:resolved] || options[:all_resolved] || party.resolved?
        else
          party.resolved = options[:all_resolved] || party.resolved?
          party.viewed = false
          party.inbox = true if party.watch?
        end
        party.save      
      end
      # this is unfortunate, because perhaps we have already just modified the page?
      page.resolved = options[:all_resolved] || page.resolved?
      page.updated_at = now
      page.updated_by = self
      page.changed :updated_by
      page.save
    end

    # sends a page to a particular user, granting them access if needed
    # 
    # options may include:
    # * +:message => 'text to send to user'+ (default is empty)
    # * +:access => 'admin'+ (or one of 'admin', 'edit', 'view'. default is 'view')
    # TODO actually really make the default 'view', instead of 'admin'
    def share_page_with_user(page, user, options={})
      access = (options[:access] || :admin).to_sym
      
      # check & update permissions

      if page.public? and !self.may_pester?(user)
        errors.add_to_base '%s is not allowed to send a page to %s' % [self.login, user.login]
        return false
      elsif !user.may?(access, page)
        if !self.may?(:admin,page)
          errors.add_to_base '%s is not allowed to change the access permissions of this page' % self.login
          return false
        elsif !self.may_pester?(user)
          errors.add_to_base '%s is not allowed to send a page to %s' % [self.login, user.login]
          return false
        else
          page.add user, :access => access
        end
      end

      # When we get here, the user should have access to the page
      # and we have confirmed that the current_user may pester them.
      # If the user may already view the page, then current_user
      # is always allowed to pester them (except for public pages)
      
      # send the message
      notice = options[:message] ? {:user_login => self.login, :message => options[:message], :time => Time.now} : nil
      page.add(user, :notice => notice)
      page.save
    end

    def share_page_with_group(page, group, options={})
      access = (options[:access] || :admin).to_sym
      unless group.may?(access,page)
        unless self.may?(:admin,page) and self.may_pester?(group)
          errors.add_to_base '%s is not allowed to send a page to %s' % [self.login, group.name]
          return false
        else
          page.add group, :access => access
          page.save
        end
      end
       
      # when we get here, the group should be able to view the page.
      group.users.select do |user|
        self.may_pester?(user)
      end # returns an array of users that might get a message
    end

  end # end Pages

  
  module CacheColumns
    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      ## serialize_as
      ## ---------------------------------
      ##
      ## usage:
      ##
      ## class Tree < ActiveRecord::Base
      ##   serialize_as IntArray, :branches, :roots
      ## end
      ##
      ## In this case, the column 'branches' will be serialized and unserialized
      ## using the IntArray.to_s and IntArray.new methods (respectively).
      ##
      ## It would be cool if I made this into a plugin, but then again, a lot
      ## of things would be cool.
      ##
      def serialize_as(klass, *keywords)
        for word in keywords
          word = word.id2name
          module_eval <<-"end_eval"
            def #{word}=(value)
              @#{word} = #{klass.to_s}.new(value)
              write_attribute('#{word}', @#{word}.to_s)
            end
            def #{word}
              @#{word} ||= #{klass.to_s}.new( read_attribute('#{word}') )
            end
          end_eval
        end
      end
      
      ## initialized_by
      ## ---------------------------------
      ##
      ## usage:
      ##
      ## class Tree < ActiveRecord::Base
      ##   initialized_by :my_method, :my_attribute
      ## end
      ##
      ## In this case, my_method() will be called each time my_attribute()
      ## is accessed if my_attribute is nil.
      ##
      def initialized_by(method, *attributes)
        method = method.id2name
        for attribute in attributes
          attribute = attribute.id2name
          module_eval <<-"end_eval"
            alias_method :#{attribute}_without_initialize, :#{attribute}
            def #{attribute}
              self.#{method}() if read_attribute('#{attribute}').nil?
              #{attribute}_without_initialize()
            end
          end_eval
        end
      end

    end
    
  end

end
