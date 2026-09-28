import NIOPosix

public enum NIOTransportGroup {
    public static let shared: MultiThreadedEventLoopGroup = .singleton
}
