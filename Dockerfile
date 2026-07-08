# Build stage
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Restore first (better layer caching)
COPY Booker.csproj ./
RUN dotnet restore Booker.csproj

# Build and publish
COPY . ./
RUN dotnet publish Booker.csproj -c Release -o /app /p:UseAppHost=false

# Runtime stage
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
COPY --from=build /app ./

# Kestrel listens on 8080 inside the container; Fly's proxy forwards to it.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "Booker.dll"]
