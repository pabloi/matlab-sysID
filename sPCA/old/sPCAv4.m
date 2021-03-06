function [C,J,X,B,D,r2,V] = sPCAv4(Y,order,forcePCS,nullBD)
%sPCA or smooth PCA, aims at estimating a best-fit space-state model from
%given outputs Y, and assuming constant input. It is similar to cPCA, but
%it doesn't purposefully identify the canonical states
%It returns the a (best in some sense?) fit of the form Y'~C*X + B ; with X(i+1,:)=A*X(i,:)+D
%where C are the first #order PCs from PCA, and A is a matrix with strictly real 
%& different eigen-vectors (no complex or double-pole solutions allowed)
%X is scaled such that X(0)=1 for all states.
%INPUTS:
%Y = N x D data matrix, representing N samples of d-dimensional data
%order: number of principal components to be estimated
%forcePCS: flag to indicate if the solution is constrained to be a linear transformation of the PCA subspace determined by first #order PCs
%OUTPUTS:
%C: D x order matrix, representing map from states to output (Y) minus constant (D)
%A: evolution matrix for states, such that X(:,i+1)=A*X(:,i)+B
%X: smoothed state estimators
%B:
%D:
%r2: r^2 of data to reconstruction
%V: transformation from PCA's PCs to canonic states (only makes sense if forcePCS=true)
%See also: sPCA_knownYinf

% Pablo A. Iturralde - Univ. of Pittsburgh - Last rev: Jun 14th 2017 %Need
% to update description


if nargin<2 || isempty(order)
    order=2; %Minimum order for which this makes sense
end
if nargin<3 || isempty(forcePCS)
    forcePCS=false; %If true, this flag forces the columns of C to lie in the subspace spanned by the first #order PCs from PCA
end
if nargin<4 || isempty(nullBD)
    nullBD=false;
end

NN=size(Y,1); %Number of samples
DD=size(Y,2); %Dimensionality of data
realPolesOnly=true; %Only acceptable value right now

%% Find a first solution: PCA + dynamic fit over PCA coefficients: fast and good enough
%Do PCA to extract the #order most meaningful PCs:
if ~nullBD
    mY=mean(Y,1); %Better-conditioned problem(?) if we remove the mean first, but less optimal(?)
else
    mY=0;
end
M=order;
YY=(Y-mY)';
[p,c,a]=pca(YY,'Centered',false);
CD=c(:,1:M);
P=p(:,1:M)';
if ~nullBD
    CD=[CD mY'];
    P=[P;ones(1,size(P,2))];
end

%Estimate dynamics:
[J,B,X] = estimateDynv2(P, realPolesOnly, nullBD,[]);
CD=(CD*P)/X;
if ~forcePCS
    CD=YY/X; %This improves r2 slightly
end

%% Optimize solution: %Estimating J,B,CD altogether, is slow and in practice improves very little (convergence issues?)
%  if ~forcePCS %No improvement possible if forcePCS=true
%      [J,B,X] = estimateDynv2(YY, realPolesOnly, nullBD,J); 
%      CD=YY/X;
%  end

%% Decompose solution:
C=CD(:,1:order);
if ~nullBD
    D=CD(:,order+1)+mY';
    X=X(1:order,:);
else
    D=0;
end

%% Change initial states, as convention, when nullBD=0 such that x(0)=0 and states grow
if ~nullBD
    [B,D,X]=chngInitState(J,B,C,D,X,zeros(size(X,1),1));
    B=-B;
    C=-C;
    X=-X;
end
%% Reconstruction values:
%rA=1-norm(X(:,2:end)-J*X(:,1:end-1)-B,'fro')^2/norm(Y','fro')^2 %This has to be exactly 1
r2=1-norm(Y'-(C*X+D),'fro')^2/norm(Y','fro')^2;
end

function [B1,D1,X1]=chngInitState(A,B,C,D,X,newX0)
    %Taking an SSM-LTI with some given state trajectories, we can re-define
    %the initial state arbitrarily by modifying B and D, such that we get a
    %modified LTI-SSM with the same output, same A,C matrices but different B,D,x0
    oldX0=X(:,1);
    Dx0=newX0-oldX0;
    B1=B-(A-eye(size(A)))*Dx0;
    D1=D-C*Dx0;
    X1=X+Dx0;
end

