import Fluent
import Vapor
import Redis

/// All API endpoints are protected by a minimum user access level.
/// This `enum` structure MUST match the values in `CreateCustomEnums` in SchemaCreation.swift
/// as this enum is part of the database schema. This enum is also sent out in several Data Transfer Object types.
/// Think very carefully about modifying these values.
enum UserAccessLevel: String, Codable {
	/// A user account that has been banned. [cannot log in]
	case banned
	/// A user account that has not yet been activated. [read-only, limited]
	case unverified
	/// A `.verified` user account that has triggered Moderator review. [read-only]
	case quarantined
	/// A user account that has been activated for full read-write access.
	case verified
	/// A special class of account for registered API clients. [see `ClientController`]
	case client
	/// An account whose owner is part of the Moderator Team.
	case moderator
	/// Twitarr devs should have their accounts elevated to this level to help handle seamail to 'twitarrteam'
	case twitarrteam
	/// An account officially associated with Management, has access to all `.moderator`
	/// and a subset of `.admin` functions (the non-destructive ones). Can ban users.
	case tho
	/// An Administrator account, unrestricted access.
	case admin
}

extension UserAccessLevel {

	// Similar to the built-in `init(rawValue:)`, but lets us decouple string values from the enum names if necessary.
	// Useful for passing accesslevels through API calls or retrieving them from the db.
	// There's no customization for the inverse; `.rawValue` should be considered canonical. 
	init?(fromRawString str: String) {
		switch str.lowercased() {
		case "banned": self = .banned
		case "unverified": self = .unverified
		case "quarantined": self = .quarantined
		case "verified": self = .verified
		case "client": self = .client
		case "moderator": self = .moderator
		case "twitarrteam": self = .twitarrteam
		case "tho": self = .tho
		case "admin": self = .admin
		default: return nil
		}
	}

	// Produces user-facing names for userLevels. Used to describe userLevels in the UI.
	func visibleName() -> String {
		switch self {
		case .unverified: return "Unverified"
		case .banned: return "Banned"
		case .quarantined: return "Quarantined"
		case .verified: return "Verified"
		case .client: return "Client"
		case .moderator: return "Moderator"
		case .twitarrteam: return "TwitarrTeam"
		case .tho: return "THO"
		case .admin: return "Administrator"
		}
	}

	/// Ensures that the access level of self grants at least the access level given in `level`.
	/// That is, UserAccessLevel.admin.hasAccess(.verified) returns true, while moderator.hasAccess(.admin) returns false.
	/// Although this currently uses > to test, the method could be expanded to non-hierarchy access types--and we may need to,
	/// as `Client`s can make calls that `Moderator`s cannot, and vice versa.
	func hasAccess(_ level: UserAccessLevel) -> Bool {
		return self >= level
	}

	// MARK: Capability Queries

	/// Returns TRUE iff this user is allowed to post their own content and edit or delete content they created..
	func canCreateContent() -> Bool {
		return self >= UserAccessLevel.verified
	}

	/// Returns TRUE if this user is allowed to moderate others' content. This includes editing text, removing images, and
	/// deleting posts. This capability does not include the ability to moderate users themselves.
	func canEditOthersContent() -> Bool {
		return self >= UserAccessLevel.moderator
	}

	/// Returns TRUE if this user can change the access level of other users. The access level of Client users cannot be changed,
	/// and only `admin` level users can set other users' access level to equal their own. For example `moderator` users can
	/// change user levels FROM any of [unverified, banned, quarantined, verified] TO any of [unverified, banned, quarantined, verified].
	func canModerateUsers() -> Bool {
		return self >= UserAccessLevel.moderator
	}
}

extension UserAccessLevel: Comparable {
	public static func < (lhs: UserAccessLevel, rhs: UserAccessLevel) -> Bool {
		func orderFromEnum(val: Self) -> Int {
			switch val {
			case .banned: return 1
			case .unverified: return 2
			case .quarantined: return 3
			case .verified: return 4
			case .client: return 5
			case .moderator: return 6
			case .twitarrteam: return 7
			case .tho: return 8
			case .admin: return 9
			}
		}
		return orderFromEnum(val: lhs) < orderFromEnum(val: rhs)
	}
}

extension UserAccessLevel: RESPValueConvertible {
    /// Attempts to create a new instance of the conforming type based on the value represented by the `RESPValue`.
    /// - Parameter value: The `RESPValue` representation to attempt to initialize from.
	public init?(fromRESP value: RESPValue){
		guard let strValue = value.string, let val = UserAccessLevel(fromRawString: strValue) else {
			return nil
		}
    	self = val
    }

    /// Creates a `RESPValue` representation of the conforming type's value.
   public func convertedToRESPValue() -> RESPValue {
    	return RESPValue(from: self.rawValue)
    }
}

