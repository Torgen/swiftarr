import Vapor
import Fluent


// MARK: - ModelAuthenticatable Conformance

extension User: ModelAuthenticatable {
    /// Required username key for HTTP Basic Authorization.
    static let usernameKey = \User.$username
    /// Required password key for HTTP Basic Authorization.
    static let passwordHashKey = \User.$password

	func verify(password: String) throws -> Bool {
		try Bcrypt.verify(password, created: self.password)
	}
}

extension User: ModelSessionAuthenticatable { }


// MARK: - Functions

extension User {

    /// Returns the `Barrel` of the given thype for the request's `User`, or nil
    /// if none exists.
    ///
    /// - Parameters:
    ///   - user: The user who owns the barrel.
    ///   - req: The incoming `Request`, on whose event loop this must run.
    /// - Returns: `Barrel` of the required type, or `nil`.
    func getBookmarkBarrel(of type: BarrelType, on req: Request) -> EventLoopFuture<Barrel?> {
    	do {
			return try Barrel.query(on: req.db)
				.filter(\.$ownerID, .equal, self.requireID())
				.filter(\.$barrelType, .equal, type)
				.first()
		}
		catch {
			return req.eventLoop.makeFailedFuture(error)
		}
    }
	
    /// Returns whether a bookmarks barrel contains the provided integer ID value.
    ///
    /// - Parameters:
    ///   - value: The Int ID value being queried.
    ///   - req: The incoming `Request`, on whose event loop this must run.
    /// - Returns: `Bool` true if the barrel contains the value, else false.
    func hasBookmarked(_ object: UserBookmarkable, on req: Request) -> EventLoopFuture<Bool> {
    	do {
			return try Barrel.query(on: req.db)
				.filter(\.$ownerID, .equal, self.requireID())
				.filter(\.$barrelType, .equal, object.bookmarkBarrelType)
				.first()
				.flatMapThrowing { (barrel) in
					guard let barrel = barrel else {
						return false 
					}
					return try barrel.userInfo["bookmarks"]?.contains(object.bookmarkIDString()) ?? false
				}
		}
		catch {
			return req.eventLoop.makeFailedFuture(error)
		}
    }
    
    /// Returns a list of IDs of all accounts associated with the `User`. If user is a primary
    /// account (has no `.parentID`) it returns itself plus any sub-accounts. If user is a
    /// sub-account, it determines its parent, then returns the parent and all sub-accounts.
    ///
    /// - Parameter req: The incoming request `Container`, which provides the `EventLoop` on
    ///   which the query must be run.
    /// - Returns: `[UUID]` containing all the user's associated IDs.
    func allAccountIDs(on req: Request) -> EventLoopFuture<[UUID]> {
    	let parID = self.parent?.id ?? self.id
    	guard let parent = parID else {
    		return req.eventLoop.makeSucceededFuture([])
    	}
		return User.query(on: req.db).group(.or) { (or) in
            or.filter(\.$id == parent)
            or.filter(\.$parent.$id == parent)
        }.all()
            .flatMapThrowing { (users) in
                return try users.map { try $0.requireID() }
        	}
    }
        
    /// Returns the parent `User` of the user sending the request. If the requesting user has
    /// no parent, the user itself is returned.
    ///
    /// - Parameter req: The incoming request `Container`, which provides reference to the
    ///   sending user.
    func parentAccount(on req: Request) throws -> EventLoopFuture<User> {
    	if self.$parent.value == nil {
    		return req.eventLoop.makeSucceededFuture(self)
    	}
    	return self.$parent.load(on: req.db).map { self.parent }
				.unwrap(or: Abort(.internalServerError, reason: "parent not found"))
    }
    
    func buildUserSearchString() {
		var builder = [String]()
		builder.append(displayName ?? "")
		builder.append(builder[0].isEmpty ? "@\(username)" : "(@\(username))")
		if let realName = realName {
			builder.append("- \(realName)")
		}
		userSearch = builder.joined(separator: " ").trimmingCharacters(in: .whitespaces)
		profileUpdatedAt = Date()
    }
    
    /// Ensures that either the receiver can edit/delete other users' content (that is, they're a moderator), or that 
    /// they authored the content they're trying to modify/delete themselves, and still have rights to edit
	/// their own content (that is, they aren't banned/quarantined).
	func guardCanCreateContent(customErrorString: String = "user cannot modify this content") throws {
		if let quarantineEndDate = tempQuarantineUntil {
			guard Date() > quarantineEndDate else {
				throw Abort(.forbidden, reason: "User is temporarily quarantined and cannot create content.")
			}
		}
		guard accessLevel.canCreateContent() else {
			throw Abort(.forbidden, reason: customErrorString)
		}
	}
    
    /// Ensures that either the receiver can edit/delete other users' content (that is, they're a moderator), or that 
    /// they authored the content they're trying to modify/delete themselves, and still have rights to edit
	/// their own content (that is, they aren't banned/quarantined).
	func guardCanModifyContent<T: Reportable>(_ content: T, customErrorString: String = "user cannot modify this content") throws {
		if let quarantineEndDate = tempQuarantineUntil {
			guard Date() > quarantineEndDate else {
				throw Abort(.forbidden, reason: "User is temporarily quarantined and cannot modify content.")
			}
		}
		let userIsContentCreator = try requireID() == content.authorUUID
		guard accessLevel.canEditOthersContent() || (userIsContentCreator && accessLevel.canCreateContent() &&
				(content.moderationStatus == .normal || content.moderationStatus == .modReviewed)) else {
			throw Abort(.forbidden, reason: customErrorString)
		}
		// If a mod reviews some content, and then the user edits their own content, it's no longer moderator reviewed.
		// This code assumes the content is going to get saved by caller.
		if userIsContentCreator && content.moderationStatus == .modReviewed {
			content.moderationStatus = .normal
		}
	}
    
    /// The receiver is the user performing the edit. `ofUser` may be nil if the reciever is editing their own profile. If it's a moderator editing another user's profile,
    /// remember that the receiver is the moderator, and the user whose profile is being edited is the ofUser parameter.
    ///
    /// This fn is very similar to `guardCanModifyContent()`; it's a separate function because profile editing is  likely to have different access requirements.
    /// In particular we're likely to let unverified users edit their profile.
	func guardCanEditProfile(ofUser profileOwner: User? = nil, customErrorString: String = "User cannot edit profile") throws {
		if let quarantineEndDate = tempQuarantineUntil {
			guard Date() > quarantineEndDate else {
				throw Abort(.forbidden, reason: "User is temporarily quarantined and cannot modify content.")
			}
		}
		let profileBeingEdited = profileOwner ?? self
		let editingOwnProfile = try profileOwner == nil || requireID() == profileOwner?.requireID()
		guard accessLevel.canEditOthersContent() || (editingOwnProfile && accessLevel.canCreateContent() &&
				(profileBeingEdited.moderationStatus == .normal || profileBeingEdited.moderationStatus == .modReviewed)) else {
			throw Abort(.forbidden, reason: customErrorString)
		}
	}
}

// users can be reported
extension User: Reportable {
	
    /// The report type for `User` reports.
	var reportType: ReportType { .user }
    
	var authorUUID: UUID { id ?? UUID() }

	var autoQuarantineThreshold: Int { Settings.shared.userAutoQuarantineThreshold }
}
