function [A,B,C,D,Q,R,X,P]=randomStartEM(Y,U,nd,Nreps,method)
if nargin<4 || isempty(Nreps)
    Nreps=20;
end
if nargin<5 || isempty(method)
   method='true'; 
end %TODO: if method is given, check that it is 'true' or 'fast'

%First iter:
[A,B,C,D,Q,R,X,P]=trueEM(Y,U,nd,[],1); %FastEM
bestLL=dataLogLikelihood(Y,U,A,B,C,D,Q,R,X(:,1),P(:,:,1));
N=size(Y,2);

switch method
    case 'true'
        fastFlag=0;
    otherwise
        fastFlag=1;
end

for i=2:Nreps
    disp(['Starting rep ' num2str(i) '. Best logL so far=' num2str(bestLL)]);
    %Xguess=randn(D1,N);
    x01=randn(nd,1);
    P01=randn(nd,nd);
    A1=randn(nd,nd);
    B1=ones(nd,size(U,1)); %WLOG
    C1=randn(size(Y,1),nd);
    D1=randn(size(Y,1),1);
    Q1=randn*eye(nd);
    R1=randn*eye(size(Y,1));
    [Xguess]=statKalmanSmoother(Y,A1,C1,Q1,R1,x01,P01,B1,D1,U);
    Xguess=medfilt1(Xguess,9,[],2);
    
    [Ai,Bi,Ci,Di,Qi,Ri,Xi,Pi]=trueEM(Y,U,Xguess,bestLL,fastFlag);
    logl=dataLogLikelihood(Y,U,Ai,Bi,Ci,Di,Qi,Ri,Xi(:,1),Pi(:,:,1));
    if logl>bestLL
        A=Ai; B=Bi; C=Ci; D=Di; Q=Qi; R=Ri; X=Xi; P=Pi;
        bestLL=logl;
        disp(['Success, best logL=' num2str(bestLL)])
    end
end
disp(['End. Best logL=' num2str(logl)]);
end